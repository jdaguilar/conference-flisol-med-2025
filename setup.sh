#!/usr/bin/env bash

set -euo pipefail

# Global variable
export MINIO_PROFILE_NAME="minio-local"

# Function definitions
print_info() {
    echo -e "\e[32m* $1\e[0m"
}

print_warn() {
    echo -e "\e[33m* WARNING: $1\e[0m"
}

print_error() {
    echo -e "\e[31m* ERROR: $1\e[0m"
    exit 1
}

install_microk8s() {
    print_info "Installing Snap MicroK8S..."
    sudo snap install microk8s --channel=1.28-strict/stable

    print_info "Setting alias 'kubectl' to microk8s.kubectl"
    sudo snap alias microk8s.kubectl kubectl

    print_info "Adding user ${USER} to microk8s group..."
    sudo usermod -a -G snap_microk8s "$USER" || print_error "Failed to add user to group"

    print_info "Creating and setting ownership of '~/.kube' directory..."
    mkdir -p ~/.kube
    sudo chown -f -R "$USER" ~/.kube
    sudo chmod -R a+r ~/.kube || print_error "Failed to manage ~/.kube directory"

    print_info "Waiting for microk8s to be ready..."
    sudo microk8s status --wait-ready || print_error "Microk8s is not ready"

    print_info "Generating Kubernetes configuration file..."
    sudo microk8s config >~/.kube/config || print_error "Failed to generate kubeconfig"

    print_info "Enabling RBAC..."
    sudo microk8s enable rbac || print_error "Failed to enable RBAC"

    print_info "Enabling storage and hostpath-storage..."
    sudo microk8s enable storage hostpath-storage || print_error "Failed to enable storage options"
}

configure_metallb() {
    print_info "Enabling metallb and configuring..."

    if ! command -v jq &>/dev/null; then
        print_warn "jq is not installed. Load balancing configuration might fail."
    fi

    local ipaddr
    ipaddr=$(ip -4 -j route get 2.2.2.2 | jq -r '.[] | .prefsrc')

    if [[ -z "$ipaddr" ]]; then
        print_warn "Failed to retrieve IP address. Load balancing might not work."
    else
        sudo microk8s enable metallb:"$ipaddr-$ipaddr" || print_error "Failed to enable metallb"
    fi
}

install_additional_tools() {
    print_info "Installing Snap AWS-CLI..."
    sudo snap install aws-cli --classic || print_error "Failed to install AWS-CLI"

    print_info "Installing Snap Spark Client..."
    sudo snap install spark-client --channel 3.4/edge || print_error "Failed to install Spark Client"

    # Adding Helm repos and ignoring errors if the repo already exists
    sudo microk8s helm repo add nessie-helm https://charts.projectnessie.org || true
    sudo microk8s helm  repo update
}

configure_spark() {
    print_info "Creating namespace 'spark'..."
    kubectl get namespace | grep -q "^spark " || kubectl create namespace spark

    if ! command -v spark-client.service-account-registry &>/dev/null; then
        print_error "spark-client.service-account-registry command not found. Skipping Spark configuration."
    fi

    print_info "Creating service account for Spark..."
    kubectl get serviceaccount -n spark | grep -q "^spark " || spark-client.service-account-registry create --username spark --namespace spark

    print_info "Getting service account configuration..."
    spark-client.service-account-registry get-config --username spark --namespace spark

    print_info "View service accounts"
    kubectl get serviceaccounts -n spark

    print_info "View roles"
    kubectl get roles -n spark

    print_info "View role bindings"
    kubectl get rolebindings -n spark
}

deploy_minio_microk8s() {
    print_info "Enabling MinIO through microk8s"
    sudo microk8s enable minio

    export AWS_ACCESS_KEY=$(kubectl get secret -n minio-operator microk8s-user-1 -o jsonpath='{.data.CONSOLE_ACCESS_KEY}' | base64 -d)
    export AWS_SECRET_KEY=$(kubectl get secret -n minio-operator microk8s-user-1 -o jsonpath='{.data.CONSOLE_SECRET_KEY}' | base64 -d)

    # Wait for the MinIO service to be ready
    while ! kubectl get service minio -n minio-operator &>/dev/null; do
        print_info "Waiting for MinIO service to be ready..."
        sleep 10
    done

    export AWS_S3_ENDPOINT=$(kubectl get service minio -n minio-operator -o jsonpath='{.spec.clusterIP}')

    # Configure AWS CLI profile for MinIO
    aws configure set aws_access_key_id "$AWS_ACCESS_KEY" --profile "$MINIO_PROFILE_NAME"
    aws configure set aws_secret_access_key "$AWS_SECRET_KEY" --profile "$MINIO_PROFILE_NAME"
    aws configure set region "us-west-2" --profile "$MINIO_PROFILE_NAME"
    aws configure set endpoint_url "http://$AWS_S3_ENDPOINT" --profile "$MINIO_PROFILE_NAME"

    print_info "AWS CLI configuration for MinIO has been set under the profile '$MINIO_PROFILE_NAME'"
    print_info "To use this profile, add --profile $MINIO_PROFILE_NAME to your AWS CLI commands"

    local minio_ui_ip minio_ui_port minio_ui_url
    minio_ui_ip=$(kubectl get service microk8s-console -n minio-operator -o jsonpath='{.spec.clusterIP}')
    minio_ui_port=$(kubectl get service microk8s-console -n minio-operator -o jsonpath='{.spec.ports[0].port}')
    minio_ui_url=$minio_ui_ip:$minio_ui_port
    echo "MinIO UI URL: $minio_ui_url"
}

create_s3_buckets() {
    local buckets=("raw" "curated" "analytics" "artifacts" "logs" "dremio" "warehouse")

    for bucket in "${buckets[@]}"; do

        if echo $(aws s3 ls "s3://$bucket" --profile $MINIO_PROFILE_NAME 2>&1) | grep -q 'NoSuchBucket'; then
            aws s3 mb "s3://$bucket" --profile $MINIO_PROFILE_NAME
        else
            echo "Bucket s3://$bucket already exists. Skipping creation."
        fi
    done

    # Special case for logs
    aws s3api put-object --bucket=logs --key=spark-events/ --profile=$MINIO_PROFILE_NAME
}

deploy_dremio() {

    print_info "Creating namespace 'dremio'..."
    kubectl get namespace | grep -q "^dremio " || kubectl create namespace dremio

    print_info "Deploy Dremio..."
    mkdir -p k8s/dremio
    cat <<EOF > k8s/dremio/values.yaml
coordinator:
  cpu: 2
  memory: 4096

executor:
  cpu: 2
  memory: 4096
  count: 1

zookeeper:
  image: zookeeper
  imageTag: 3.8.4-jre-17
  cpu: 0.5
  memory: 1024
  count: 1

distStorage:
  type: "aws"

  aws:
    bucketName: "dremio"
    path: "/"
    authentication: "accessKeySecret"
    credentials:
      accessKey: $AWS_ACCESS_KEY
      secret: $AWS_SECRET_KEY

    extraProperties: |
      <property>
          <name>fs.dremioS3.impl</name>
          <description>The FileSystem implementation. Must be set to com.dremio.plugins.s3.store.S3FileSystem</description>
          <value>com.dremio.plugins.s3.store.S3FileSystem</value>
      </property>
      <property>
          <name>fs.s3a.access.key</name>
          <description>Minio server access key ID.</description>
          <value>$AWS_ACCESS_KEY</value>
      </property>
      <property>
          <name>fs.s3a.secret.key</name>
          <description>Minio server secret key.</description>
          <value>$AWS_SECRET_KEY</value>
      </property>
      <property>
          <name>fs.s3a.aws.credentials.provider</name>
          <description>The credential provider type.</description>
          <value>org.apache.hadoop.fs.s3a.SimpleAWSCredentialsProvider</value>
      </property>
      <property>
          <name>fs.s3a.endpoint</name>
          <description>Endpoint can be either an IP or a hostname where Minio server is running. However, the endpoint value cannot contain the 'http(s)://' prefix nor can it start with the string s3. For example, if the endpoint is 'http://175.1.2.3:9000', the value is '175.1.2.3:9000'.</description>
          <value>$AWS_S3_ENDPOINT</value>
      </property>
      <property>
          <name>fs.s3a.path.style.access</name>
          <description>Value has to be set to true.</description>
          <value>true</value>
      </property>
      <property>
          <name>dremio.s3.compat</name>
          <description>Value has to be set to true.</description>
          <value>true</value>
      </property>
      <property>
          <name>fs.s3a.connection.ssl.enabled</name>
          <description>Value can either be true or false, set to true to use SSL with a secure Minio server.</description>
          <value>false</value>
      </property>

EOF
    sudo microk8s helm upgrade --install my-dremio -n dremio -f k8s/dremio/values.yaml  k8s/charts/dremio_v2

    # Wait for the MinIO service to be ready
    while ! kubectl get service dremio-client -n dremio &>/dev/null; do
        print_info "Waiting for Dremio service to be ready..."
        sleep 10
    done

    dremio_ui_ip=$(kubectl get service dremio-client -n dremio -o jsonpath='{.spec.clusterIP}')
    dremio_ui_port=$(kubectl get service dremio-client -n dremio -o jsonpath='{.spec.ports[1].port}')
    dremio_ui_url=$dremio_ui_ip:$dremio_ui_port
    echo "Dremio UI URL: http://$dremio_ui_url"
}

deploy_nessie() {
    print_info "Creating namespace 'nessie'..."
    kubectl get namespace | grep -q "^nessie " || kubectl create namespace nessie

    print_info "Deploy Nessie..."
    sudo microk8s helm upgrade --install -n nessie-ns nessie nessie-helm/nessie --create-namespace
}

configure_spark_settings() {

    export AWS_ACCESS_KEY=$(kubectl get secret -n minio-operator microk8s-user-1 -o jsonpath='{.data.CONSOLE_ACCESS_KEY}' | base64 -d)
    export AWS_SECRET_KEY=$(kubectl get secret -n minio-operator microk8s-user-1 -o jsonpath='{.data.CONSOLE_SECRET_KEY}' | base64 -d)
    export AWS_S3_ENDPOINT=$(kubectl get service minio -n minio-operator -o jsonpath='{.spec.clusterIP}')

    spark-client.service-account-registry add-config \
        --username spark --namespace spark \
        --conf spark.eventLog.enabled=true \
        --conf spark.eventLog.dir=s3a://logs/spark-events/ \
        --conf spark.history.fs.logDirectory=s3a://logs/spark-events/ \
        --conf spark.hadoop.fs.s3a.aws.credentials.provider=org.apache.hadoop.fs.s3a.SimpleAWSCredentialsProvider \
        --conf spark.hadoop.fs.s3a.connection.ssl.enabled=false \
        --conf spark.hadoop.fs.s3a.path.style.access=true \
        --conf spark.hadoop.fs.s3a.access.key="$AWS_ACCESS_KEY" \
        --conf spark.hadoop.fs.s3a.endpoint="$AWS_S3_ENDPOINT" \
        --conf spark.hadoop.fs.s3a.secret.key="$AWS_SECRET_KEY" \
        --conf spark.kubernetes.namespace=spark

    spark-client.service-account-registry get-config \
            --username spark --namespace spark

    spark-client.service-account-registry get-config \
        --username spark --namespace spark > properties.conf
}


# Main execution
main() {
    install_microk8s
    # configure_metallb
    install_additional_tools
    configure_spark
    deploy_minio_microk8s
    create_s3_buckets
    deploy_dremio
    deploy_nessie
    configure_spark_settings
    }

main "$@"
