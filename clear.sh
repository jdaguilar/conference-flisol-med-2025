sudo kubectl delete namespace spark
sudo kubectl delete namespace nessie
sudo kubectl delete namespace dremio
sudo kubectl delete namespace minio-operator

sudo microk8s kubectl-minio delete -y
sudo microk8s disable rbac -y
sudo microk8s disable storage -y
sudo microk8s disable hostpath-storage -y
sudo microk8s disable metallb -y

sudo snap remove microk8s --purge
