#!/bin/bash

function etcd::test_encryption() {
  kubectl create secret generic kubernetes-the-hard-way \
  --from-literal="mykey=mydata"
  
  sudo ETCDCTL_API=3 etcdctl get \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ca.crt \
  --cert=/etc/etcd/etcd-server.crt \
  --key=/etc/etcd/etcd-server.key\
  /registry/secrets/default/kubernetes-the-hard-way | hexdump -C

  echo "The etcd key should be prefixed with k8s:enc:aescbc:v1:key1, which indicates the aescbc provider was used to encrypt the data with the key1 encryption key."
}

function deployment::test() {
  kubectl create deployment nginx --image=nginx
  kubectl get pods -l app=nginx
}

function service::test() {
  kubectl expose deploy nginx --type=NodePort --port 80
  PORT_NUMBER=$(kubectl get svc -l app=nginx -o jsonpath="{.items[0].spec.ports[0].nodePort}")
  curl http://worker-1:$PORT_NUMBER
  curl http://worker-2:$PORT_NUMBER
}

function node-log::test-get-pod-log() {
  POD_NAME=$(kubectl get pods -l app=nginx -o jsonpath="{.items[0].metadata.name}")
  kubectl logs $POD_NAME
}

function node-exec::test-exec-pod() {
  POD_NAME=$(kubectl get pods -l app=nginx -o jsonpath="{.items[0].metadata.name}")
  kubectl exec -ti $POD_NAME -- nginx -v
}

function e2e::install() {
  # install go
  wget https://dl.google.com/go/go1.12.1.linux-amd64.tar.gz

  sudo tar -C /usr/local -xzf go1.12.1.linux-amd64.tar.gz
  export GOPATH="/home/vagrant/go"
  export PATH=$PATH:/usr/local/go/bin:$GOPATH/bin

  # install kubetest
  go get -v -u k8s.io/test-infra/kubetest
  kubetest --extract=v1.13.0
  cd kubernetes
  export KUBE_MASTER_IP="192.168.5.11:6443"
  export KUBE_MASTER=master-1
  kubetest --test --provider=skeleton --test_args="--ginkgo.focus=\[Conformance\]" | tee test.out
}

function main() {
  etcd::test_encryption
  deployment::test
  service::test
  node-log::test-get-pod-log

  e2e-test::install
}

main "$@"