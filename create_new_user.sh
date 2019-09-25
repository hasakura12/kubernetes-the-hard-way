#!/bin/bash
API_SERVER_IP=192.168.5.30

function usage {
	>&2 echo "
    What is this:
    A script to create new user in K8s cluster. It'll create a TLS certificate for authentication and K8s role and rolebinding for authorization.

    Usage:
    $0 NEW_USER_NAME 
    
    Examples:
    $0 hisashi
    $0 tester
	"
}

function openssl::create_csr() {
  local user_name="${1?New user name is required.}"
  
  echo "Creating CSR for ${user_name}..."
  openssl genrsa -out ${user_name}.key 2048
  openssl req -new -key ${user_name}.key -subj="/CN=${user_name}" -out ${user_name}.csr
}

function csr::request() {
  local user_name="${1?New user name is required.}"

  echo "Creating K8s CSR object for ${user_name}..."

  cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1beta1
kind: CertificateSigningRequest
metadata:
  name: ${user_name}
spec:
  request: $(cat ${user_name}.csr | base64 | tr -d '\n')
  usages:
  - digital signature
  - key encipherment
  - server auth
EOF

  kubectl get csr
}

function csr::approve() {
  local user_name="${1?New user name is required.}"

  echo "Approving CSR object for ${user_name}..."
  kubectl certificate approve ${user_name}
}

function crt::get() {
  local user_name="${1?New user name is required.}"
  
  echo "Extracting crt for ${user_name}..."

  jq --version >/dev/null 2>&1 || sudo snap install jq

  kubectl get csr ${user_name} -o json | jq .status.certificate -r >> ${user_name}.crt
}

function kubeconfig::create() {
  local user_name="${1?New user name is required.}"
  local apiserver_ip="${2?API server IP is required.}"

  echo "Creating kubeconfig for ${user_name}..."

  kubectl config set-cluster k8s-hard-way \
    --server=https://${apiserver_ip}:6443 \
    --certificate-authority=ca.crt \
    --embed-certs=true \
    --kubeconfig ${user_name}.kubeconfig
  
  kubectl config set-credentials ${user_name} \
    --client-certificate=${user_name}.crt \
    --client-key=${user_name}.key \
    --embed-certs=true \
    --kubeconfig=${user_name}.kubeconfig

  kubectl config set-context k8s-hard-way \
    --user=${user_name} \
    --kubeconfig=${user_name}.kubeconfig

  kubectl config use-context k8s-hard-way \
    --kubeconfig=${user_name}.kubeconfig

  cat ${user_name}.kubeconfig
}

function clusterrole::create() {
  local user_name="${1?New user name is required.}"

  echo "Creating clusterrole for ${user_name}..."

  kubectl create clusterrole ${user_name}-role \
    --verb=get,list,watch,create \
    --resource=deployments.extensions,rs.extensions,pods,services,*.rbac.authorization.k8s.io \
    --dry-run -o yaml > clusterrole_${user_name}.yaml
  
  kubectl apply -f clusterrole_${user_name}.yaml
}

function clusterrolebinding::create() {
  local user_name="${1?New user name is required.}"

  echo "Creating clusterrolebinding for ${user_name}..."

  kubectl create clusterrolebinding ${user_name}-binding \
    --clusterrole=${user_name}-role \
    --user=${user_name} \
    --dry-run -o yaml > clusterrolebinding_${user_name}.yaml
  
  kubectl apply -f clusterrolebinding_${user_name}.yaml
}

function clusterrole::verify() {
  local user_name="${1?New user name is required.}"

  echo "Veridying permissions for ${user_name}..."
  kubectl get pods --as ${user_name}
  kubectl auth can-i get pods --as ${user_name}
}

function user::create() {
  local user_name="${1?New user name is required.}"

  # authentication to apiserver via cert
  openssl::create_csr ${user_name}
  csr::request ${user_name}
  csr::approve ${user_name}
  crt::get ${user_name}
  kubeconfig::create ${user_name} API_SERVER_IP

  # authorization to apiserver via RBAC role
  clusterrole::create ${user_name}
  clusterrolebinding::create ${user_name}
}

function user::test_permissions() {
  local user_name="${1?New user name is required.}"

  clusterrole::verify ${user_name}
}

function main() {
  if [[ $# -lt 1 ]]; then
    usage;
  fi

  local user_name="${1?New user name is required.}"

  user::create  ${user_name}
  user::test_permissions  ${user_name}
}

main "$@"