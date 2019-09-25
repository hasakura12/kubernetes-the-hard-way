#!/bin/bash

function cert::generate_root_cert() {
  local root_ca_prefix="${1:-ca}"

  # if ca.crt exists then don't overwrite it
  if [[ -s ~/ca.crt ]]; then
    echo "ca.crt exists so do nothing..."
    exit 0;
  fi

  # create private key
  openssl genrsa -out ${root_ca_prefix}.key 2048

  # Create CSR using the private key
  openssl req -new -key ${root_ca_prefix}.key -subj "/CN=KUBERNETES-CA" -out ${root_ca_prefix}.csr

  # Self sign the csr using its own private key
  openssl x509 -req -in ${root_ca_prefix}.csr -signkey ${root_ca_prefix}.key -CAcreateserial  -out ${root_ca_prefix}.crt -days 1000

  >&2echo "Validating root cert..."
  openssl x509 -in ${root_ca_prefix}.crt -text
}

function main() {
  cert::generate_root_cert
}

main "$@"