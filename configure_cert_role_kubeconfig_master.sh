#!/bin/bash

# declare array of master nodes
master_nodes=( master-1 master-2 )
worker_nodes=( worker-1 worker-2 )

function cert::generate_cert() {
  local crt_prefix="${1:?Cert prefix name is required.}"
  local crt_subj="${2:?Subj is required.}"
  local openssl_conf="${3}"
  local root_ca_prefix="${4:-ca}"

  # Geenrate private key for admin user
  openssl genrsa -out ${crt_prefix}.key 2048

  # Generate CSR for admin user. Note the OU.
  if [ $# -eq 2 ]; then
    openssl req -new -key ${crt_prefix}.key -subj ${crt_subj} -out ${crt_prefix}.csr
  elif [ $# -eq 3 ]; then
    openssl req -new -key ${crt_prefix}.key -subj ${crt_subj} -out ${crt_prefix}.csr -config ${openssl_conf}
  fi

  # Sign certificate for admin user using CA servers private key
  if [ $# -eq 2 ]; then
    openssl x509 -req -in ${crt_prefix}.csr -CA ${root_ca_prefix}.crt -CAkey ${root_ca_prefix}.key -CAcreateserial -out ${crt_prefix}.crt -days 1000
  elif [ $# -eq 3 ]; then
    openssl x509 -req -in ${crt_prefix}.csr -CA ${root_ca_prefix}.crt -CAkey ${root_ca_prefix}.key -CAcreateserial -out ${crt_prefix}.crt -days 1000 -extensions v3_req -extfile ${openssl_conf}
  fi

  >&2echo "Validating admin cert..."
  openssl x509 -in ${crt_prefix}.crt -text
}

# pre-condition: root crt must be created already
function cert:generate_certs() {
  local admin_crt_name="${1:-admin}"
  local kube_controller_manager_name="${2:-kube-controller-manager}"
  local kube_scheduler_name="${3:-kube-scheduler}"
  local kube_proxy_name="${4:-kube-proxy}"
  local kube_apiserver_name="${5:-kube-apiserver}"
  local etcd_server_name="${6:-etcd-server}"
  local service_account_name="${7:-service-account}"

  # admin crt
  cert::generate_cert ${admin_crt_name} "/CN=admin/O=system:masters"

  # controller-manager crt
  cert::generate_cert ${kube_controller_manager_name} "/CN=system:kube-controller-manager"

  # scheduler crt
  cert::generate_cert ${kube_scheduler_name} "/CN=system:kube-scheduler"

  # kube-proxy crt
  cert::generate_cert ${kube_proxy_name} "/CN=system:kube-proxy"

  # kube-apiserver crt
  cat > openssl.cnf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = kubernetes
DNS.2 = kubernetes.default
DNS.3 = kubernetes.default.svc
DNS.4 = kubernetes.default.svc.cluster.local
IP.1 = 10.96.0.1
IP.2 = 192.168.5.11
IP.3 = 192.168.5.12
IP.4 = 192.168.5.30
IP.5 = 127.0.0.1
EOF

  cert::generate_cert ${kube_apiserver_name} "/CN=system:kube-apiserver" "openssl.cnf"

  # Etcd cert
  cat > openssl-etcd.cnf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
IP.1 = 192.168.5.11
IP.2 = 192.168.5.12
IP.3 = 127.0.0.1
EOF

  cert::generate_cert ${etcd_server_name} "/CN=etcd-server" "openssl-etcd.cnf"

  # serviceaccount cert
  cert::generate_cert ${service_account_name} "/CN=service-accounts"
}

function cert::test_certs_exists() {
  echo "Validating certs exit..."

  for crt_name in "$@"; do
    file ${crt_name}.crt
  done;
}

function cert::distribute_certs_to_master_nodes() {
  for instance in ${master_nodes[@]}; do
    echo "Ditributing certs to ${instance}..."
    scp ca.crt ca.key ${instance}:~/

    for crt_name in "$@"; do
      scp ${crt_name}.key ${crt_name}.crt ${instance}:~/
    done
  done

  for instance in ${worker_nodes[@]}; do
    echo "Ditributing root cert to ${instance}..."
    scp ca.crt ${instance}:~/
  done
}

function kubeconfig::generage_kubeconfig() {
  local crt_prefix="${1:?Cert prefix name is required.}"
  local root_ca_prefix="${2:-ca}"
  local server_ip
  local loadbalancer_ip=192.168.5.30

  # if component resides in worker node (i.e. kube-proxy), set server IP to LB IP
  [[ ${crt_prefix} = "kube-proxy" ]] && server_ip=${loadbalancer_ip} || server_ip=127.0.0.1
  
  echo "Checking kubectl installed..."
  kubectl version >/dev/null 2>&1 || sudo snap install kubectl --classic

  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=${root_ca_prefix}.crt \
    --embed-certs=true \
    --server=https://${server_ip}:6443 \
    --kubeconfig=${crt_prefix}.kubeconfig

  kubectl config set-credentials system:${crt_prefix} \
    --client-certificate=${crt_prefix}.crt \
    --client-key=${crt_prefix}.key \
    --embed-certs=true \
    --kubeconfig=${crt_prefix}.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:${crt_prefix} \
    --kubeconfig=${crt_prefix}.kubeconfig

  kubectl config use-context default --kubeconfig=${crt_prefix}.kubeconfig
}

function kubeconfig::generage_kubeconfigs() {
  local admin_crt_name="${1:-admin}"
  local kube_controller_manager_name="${2:-kube-controller-manager}"
  local kube_scheduler_name="${3:-kube-scheduler}"
  local kube_proxy_name="${4:-kube-proxy}"

  kubeconfig::generage_kubeconfig ${admin_crt_name}
  kubeconfig::generage_kubeconfig ${kube_controller_manager_name}
  kubeconfig::generage_kubeconfig ${kube_scheduler_name}
  kubeconfig::generage_kubeconfig ${kube_proxy_name}
}

function kubeconfig::test_kubeconfig_exists() {
  echo "Validating kubeconfig files exit..."

  for kubeconfig in "$@"; do
    file ${kubeconfig}.kubeconfig
  done;
}

function kubeconfig::distribute_kubeconfig() {
  for instance in ${master_nodes[@]}; do
    echo "Ditributing kubeconfig to ${instance}..."

    for kubeconfig in "$@"; do
      if [ ${kubeconfig} != "kube-proxy" ]; then
        scp ${kubeconfig}.kubeconfig ${instance}:~/
      fi
    done
  done

  for instance in ${worker_nodes[@]}; do
    echo "Ditributing kubeconfig to ${instance}..."

    for kubeconfig in "$@"; do
      if [ ${kubeconfig} = "kube-proxy" ]; then
        scp ${kubeconfig}.kubeconfig ${instance}:~/
      fi
    done
  done
}

function generate_encryption_key() {
  ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

  cat > encryption-config.yaml <<EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF

  for instance in ${master_nodes[@]}; do
    echo "Ditributing encryption_config.yaml to ${instance}..."
    scp encryption-config.yaml ${instance}:~/
  done
}

function etcd::install() {
  for instance in ${master_nodes[@]}; do
    echo "Installing Etcd in ${instance}..."
    ssh ${instance}

    {
      wget -q --show-progress --https-only --timestamping \
      "https://github.com/coreos/etcd/releases/download/v3.3.9/etcd-v3.3.9-linux-amd64.tar.gz"
      tar -xvf etcd-v3.3.9-linux-amd64.tar.gz
    }
    {
      sudo mv etcd-v3.3.9-linux-amd64/etcd* /usr/local/bin/
      sudo mkdir -p /etc/etcd /var/lib/etcd
      sudo cp ca.crt etcd-server.key etcd-server.crt /etc/etcd/
      INTERNAL_IP=$(ip addr show enp0s8 | grep "inet " | awk '{print $2}' | cut -d / -f 1)
      ETCD_NAME=$(hostname -s)

      cat <<EOF | sudo tee /etc/systemd/system/etcd.service
[Unit]
Description=etcd
Documentation=https://github.com/coreos

[Service]
ExecStart=/usr/local/bin/etcd \\
  --name ${ETCD_NAME} \\
  --cert-file=/etc/etcd/etcd-server.crt \\
  --key-file=/etc/etcd/etcd-server.key \\
  --peer-cert-file=/etc/etcd/etcd-server.crt \\
  --peer-key-file=/etc/etcd/etcd-server.key \\
  --trusted-ca-file=/etc/etcd/ca.crt \\
  --peer-trusted-ca-file=/etc/etcd/ca.crt \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --initial-advertise-peer-urls https://${INTERNAL_IP}:2380 \\
  --listen-peer-urls https://${INTERNAL_IP}:2380 \\
  --listen-client-urls https://${INTERNAL_IP}:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls https://${INTERNAL_IP}:2379 \\
  --initial-cluster-token etcd-cluster-0 \\
  --initial-cluster master-1=https://192.168.5.11:2380,master-2=https://192.168.5.12:2380 \\
  --initial-cluster-state new \\
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

      sudo systemctl daemon-reload
      sudo systemctl enable etcd
      sudo systemctl start etcd
    }
  done
}

function worker::create_bootstrap_token() {

  cat > bootstrap-token-07401b.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  # Name MUST be of form "bootstrap-token-<token id>"
  name: bootstrap-token-07401b
  namespace: kube-system

# Type MUST be 'bootstrap.kubernetes.io/token'
type: bootstrap.kubernetes.io/token
stringData:
  # Human readable description. Optional.
  description: "The default bootstrap token generated by 'kubeadm init'."

  # Token ID and secret. Required.
  token-id: 07401b
  token-secret: f395accd246ae52d

  # Expiration. Optional.
  expiration: 2021-03-10T03:22:11Z

  # Allowed usages.
  usage-bootstrap-authentication: "true"
  usage-bootstrap-signing: "true"

  # Extra groups to authenticate the token as. Must start with "system:bootstrappers:"
  auth-extra-groups: system:bootstrappers:worker
EOF

  kubectl create -f bootstrap-token-07401b.yaml
}

function worker::create_role_create_csr_for_bootstrapper() {

  cat > csrs-for-bootstrapping.yaml <<EOF
# enable bootstrapping nodes to create CSR
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: create-csrs-for-bootstrapping
subjects:
- kind: Group
  name: system:bootstrappers
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: system:node-bootstrapper
  apiGroup: rbac.authorization.k8s.io
EOF

  kubectl create -f csrs-for-bootstrapping.yaml
}

function worker::create_role_auto_approve_csr_for_bootstrapper() {
  cat > auto-approve-csrs-for-group.yaml <<EOF
# Approve all CSRs for the group "system:bootstrappers"
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: auto-approve-csrs-for-group
subjects:
- kind: Group
  name: system:bootstrappers
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: system:certificates.k8s.io:certificatesigningrequests:nodeclient
  apiGroup: rbac.authorization.k8s.io
EOF

  kubectl create -f auto-approve-csrs-for-group.yaml
}

function worker::create_role_auto_renew_csr_for_node() {
  cat > auto-approve-renewals-for-nodes.yaml <<EOF
# Approve renewal CSRs for the group "system:nodes"
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: auto-approve-renewals-for-nodes
subjects:
- kind: Group
  name: system:nodes
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: system:certificates.k8s.io:certificatesigningrequests:selfnodeclient
  apiGroup: rbac.authorization.k8s.io
EOF

  kubectl create -f auto-approve-renewals-for-nodes.yaml
}

function master::install_cni() {
  kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"
  kubectl get pods -n kube-system
}

function apiserver::create_role_access_kubelet() {
  cat <<EOF | kubectl apply --kubeconfig admin.kubeconfig -f -
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:kube-apiserver-to-kubelet
rules:
  - apiGroups:
      - ""
    resources:
      - nodes/proxy
      - nodes/stats
      - nodes/log
      - nodes/spec
      - nodes/metrics
    verbs:
      - "*"
EOF

  cat <<EOF | kubectl apply --kubeconfig admin.kubeconfig -f -
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: system:kube-apiserver
  namespace: ""
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-apiserver-to-kubelet
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: kube-apiserver
EOF
}

function coredns::install() {
  kubectl apply -f https://raw.githubusercontent.com/mmumshad/kubernetes-the-hard-way/master/deployments/coredns.yaml
  kubectl get pods -l k8s-app=kube-dns -n kube-system
}

function coredns::verify() {
  kubectl run --generator=run-pod/v1 busybox --image=busybox:1.28 --command -- sleep 3600
  kubectl get pods -l run=busybox
  kubectl exec -ti busybox -- nslookup kubernetes
}

# execute this ONLY ONCE from master node
function main(){
  local admin_crt_name="admin"
  local kube_controller_manager_name="kube-controller-manager"
  local kube_scheduler_name="kube-scheduler"
  local kube_proxy_name="kube-proxy"
  local kube_apiserver_name="kube-apiserver"
  local etcd_server_name="etcd-server"
  local service_account_name="service-account"

  cert:generate_certs \
    ${admin_crt_name} \
    ${kube_controller_manager_name} \
    ${kube_scheduler_name} \
    ${kube_proxy_name} \
    ${kube_apiserver_name} \
    ${etcd_server_name} \
    ${service_account_name}

  cert::test_certs_exists \
    ${admin_crt_name} \
    ${kube_controller_manager_name} \
    ${kube_scheduler_name} \
    ${kube_proxy_name} \
    ${kube_apiserver_name} \
    ${etcd_server_name} \
    ${service_account_name}

  cert::distribute_certs_to_master_nodes \
    ${admin_crt_name} \
    ${kube_controller_manager_name} \
    ${kube_scheduler_name} \
    ${kube_apiserver_name} \
    ${etcd_server_name} \
    ${service_account_name}

  kubeconfig::generage_kubeconfigs \
    ${admin_crt_name} \
    ${kube_controller_manager_name} \
    ${kube_scheduler_name} \
    ${kube_proxy_name}

  kubeconfig::test_kubeconfig_exists \
    ${admin_crt_name} \
    ${kube_controller_manager_name} \
    ${kube_scheduler_name} \
    ${kube_proxy_name}

  kubeconfig::distribute_kubeconfig \
    ${admin_crt_name} \
    ${kube_controller_manager_name} \
    ${kube_scheduler_name} \
    ${kube_proxy_name}

  generate_encryption_key

  worker::create_bootstrap_token
  worker::create_role_create_csr_for_bootstrapper
  worker::create_role_auto_approve_csr_for_bootstrapper
  worker::create_role_auto_renew_csr_for_node
  
  master::install_cni

  apiserver::create_role_access_kubelet

  coredns::install
  coredns::verify
}

main "$@"