# Run a Hashicorp Vault Cluster on k3s inside a gitpod container

<a href="https://gitpod.io/#https://github.com/adamfordyce11/gitpod-vault">
  <img
    src="https://img.shields.io/badge/Contribute%20with-Gitpod-908a85?logo=gitpod"
    alt="Contribute with Gitpod"
  />
</a>

# Introduction

k3s, helm, and vault is installed automatically within the GidPod environment.

The following setup is prepared during pod initialisation:
 - QEMU and supporting tools are installed
 - k3s is installed
 - A root CA is created and vault is installed with TLS enabled using the Root CA
