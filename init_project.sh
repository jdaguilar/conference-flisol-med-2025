#!/usr/bin/env bash

set -euo pipefail

# Global variable
export MINIO_PROFILE_NAME="minio-local"

# Function definitions
print_info() { echo -e "\e[32m* $1\e[0m"; }
print_warn() { echo -e "\e[33m* WARNING: $1\e[0m"; }
print_error() {
    echo -e "\e[31m* ERROR: $1\e[0m"
    exit 1
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
    configure_spark_settings

    print_info "Setup complete."
}

main "$@"
