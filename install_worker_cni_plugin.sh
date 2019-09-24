#!/bin/bash

function() prerequisite::install() {
  wget https://github.com/containernetworking/plugins/releases/download/v0.7.5/cni-plugins-amd64-v0.7.5.tgz
  sudo tar -xzvf cni-plugins-amd64-v0.7.5.tgz --directory /opt/cni/bin/
}

# execute this on each worker node
function main() {
  prerequisite::install
}

main "$@"