#!/bin/bash

# Need to follow these steps
# - https://developer.hashicorp.com/vault/tutorials/kubernetes/kubernetes-raft-deployment-guide
script_dirname="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
k3sreadylock="${script_dirname}/_output/rootfs/k3s-ready.lock"
vaultreadylock="${script_dirname}/_output/rootfs/vault-ready.lock"

# Exit if vault has already been setup
if test -f "${vaultreadylock}";
then
    exit 0
fi

# Set required variables
export VAULT_K8S_NAMESPACE="vault" \
export VAULT_HELM_RELEASE_NAME="vault" \
export VAULT_SERVICE_NAME="vault-internal" \
export K8S_CLUSTER_NAME="cluster.local" \
export WORKDIR=${script_dirname}/vault


function waitk3s() {
  while ! test -f "${k3sreadylock}"; do
    sleep 0.5
  done
}

# Run system command and check the return code is 0 or exit
function run() {
  cmd=$*
  $($*)
  if [[ $? -ne 0 ]];
  then
    echo -e "\e[31m[ INFO  ]\e[m]: $*"
    echo -e "\e[31m[ ERROR ]\e[m]: non-zero exit code from command"
    exit $?
  else:
    echo -e "\e[31m[ INFO  ]\e[m]: $*"
  fi
}

function setup_helm() {
  ${script_dirname}/wait-apt.sh
  curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
  sudo apt-get install apt-transport-https --yes
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
  sudo apt-get update
  sudo apt-get install helm
}

# Generate the tls root CA for kubernetes and store it in kubernetes
function generate_root_certificate() {
  # Generate the private key
  run openssl genrsa -out ${WORKDIR}/vault.key 2048
  # Create the CSR Configuration
  cat > ${WORKDIR}/vault-csr.conf <<EOF
[req]
default_bits = 2048
prompt = no
encrypt_key = yes
default_md = sha256
distinguished_name = kubelet_serving
req_extensions = v3_req
[ kubelet_serving ]
O = system:nodes
CN = system:node:*.${VAULT_HELM_RELEASE_NAME}.svc.${K8S_CLUSTER_NAME}
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = *.${VAULT_SERVICE_NAME}
DNS.2 = *.${VAULT_SERVICE_NAME}.${VAULT_HELM_RELEASE_NAME}.svc.${K8S_CLUSTER_NAME}
DNS.3 = *.${VAULT_HELM_RELEASE_NAME}
IP.1 = 127.0.0.1
EOF
  # Generate the CSR
  run openssl req -new -key ${WORKDIR}/vault.key -out ${WORKDIR}/vault.csr -config ${WORKDIR}/vault-csr.conf

  # Issue the Certificate
  cat > ${WORKDIR}/csr.yaml <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
   name: vault.svc
spec:
   signerName: kubernetes.io/kubelet-serving
   expirationSeconds: 8640000
   request: $(cat ${WORKDIR}/vault.csr|base64|tr -d '\n')
   usages:
   - digital signature
   - key encipherment
   - server auth
EOF
}

function add_csr_to_k8s() {
  if [[ ! -d "${WORKDIR}" ]];
  then
    echo -e "\e[31m[ ERROR ]\e[m]: The WORKDIR: ${WORKDIR} does not exist!"
    exit 1
  fi

  if [[ ! -f "${WORKDIR}/csr.yaml" ]];
  then
    echo -e "\e[31m[ ERROR ]\e[m]: The file ${WORKDIR}/csr.yaml does not exist!"
    exit 1
  fi

  # Send the CSR to kubernetes
  run kubectl create -f ${WORKDIR}/csr.yaml

  # Approve the CSR in kubernetes
  run kubectl certificate approve vault.svc

  # Verify the csr is installed
  run kubectl get csr vault.svc
  status=kubectl get csr vault.svc -o jsonpath="{.status.conditions[0].status}"
  if [[ "${status}" != "True" ]];
  then
    echo -e "\e[31m[ ERROR ]\e[m]: The CSR was not installed to kubernetes correctly"
    exit 1
  fi

  # Receive the certificate from k8s
  run kubectl get csr vault.svc -o jsonpath='{.status.certificate}' | openssl base64 -d -A -out ${WORKDIR}/vault.crt
  # Retrieve the k8s CA certificate
  run kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[].cluster.certificate-authority-data}' | base64 -d > ${WORKDIR}/vault.ca
  # Create the TLS secret
  run kubectl create secret generic vault-ha-tls \
    -n $VAULT_K8S_NAMESPACE \
    --from-file=vault.key=${WORKDIR}/vault.key \
    --from-file=vault.crt=${WORKDIR}/vault.crt \
    --from-file=vault.ca=${WORKDIR}/vault.ca

}

function generate_vault_config() {
  # Create the Vault Overrides YAML
  cat > ${WORKDIR}/overrides.yaml <<EOF
global:
   enabled: true
   tlsDisable: false
injector:
   enabled: true
server:
   extraEnvironmentVars:
      VAULT_CACERT: /vault/userconfig/vault-ha-tls/vault.ca
      VAULT_TLSCERT: /vault/userconfig/vault-ha-tls/vault.crt
      VAULT_TLSKEY: /vault/userconfig/vault-ha-tls/vault.key
   volumes:
      - name: userconfig-vault-ha-tls
        secret:
         defaultMode: 420
         secretName: vault-ha-tls
   volumeMounts:
      - mountPath: /vault/userconfig/vault-ha-tls
        name: userconfig-vault-ha-tls
        readOnly: true
   standalone:
      enabled: false
   affinity: ""
   ha:
      enabled: true
      replicas: 3
      raft:
         enabled: true
         setNodeId: true
         config: |
            ui = true
            listener "tcp" {
               tls_disable = 0
               address = "[::]:8200"
               cluster_address = "[::]:8201"
               tls_cert_file = "/vault/userconfig/vault-ha-tls/vault.crt"
               tls_key_file  = "/vault/userconfig/vault-ha-tls/vault.key"
               tls_client_ca_file = "/vault/userconfig/vault-ha-tls/vault.ca"
            }
            storage "raft" {
               path = "/vault/data"
            }
            disable_mlock = true
            service_registration "kubernetes" {}
EOF
}

# Wait for k3s to be setup before proceeding
waitk3s

# Setup helm with the hashicorp repo
run helm repo add hashicorp https://helm.releases.hashicorp.com
run helm repo update

# Create the vault namespace
run kubectl create namespace $VAULT_K8S_NAMESPACE

# Generate the TLS Certificates
generate_root_certificate

# Add the CSR to k8s
add_csr_to_k8s

# Generate the overrides.yaml file
generate_vault_config

if [[ ! -f "${WORKDIR}/overrides.yaml" ]];
then
  echo -e "\e[31m[ ERROR ]\e[m]: Vault overrides YAML not found"
  exit 1
fi

# Deploy the cluster
run helm install -n $VAULT_K8S_NAMESPACE $VAULT_HELM_RELEASE_NAME hashicorp/vault -f ${WORKDIR}/overrides.yaml

# Sleep until the pods are ready
kubectl exec -n $VAULT_K8S_NAMESPACE vault-0 -- vault operator init \
    -key-shares=1 \
    -key-threshold=1 \
    -format=json > ${WORKDIR}/cluster-keys.json

# This is unsecure
export VAULT_UNSEAL_KEY=$(jq -r ".unseal_keys_b64[]" ${WORKDIR}/cluster-keys.json)

# Unseal the vault-0 pod
kubectl exec -n $VAULT_K8S_NAMESPACE vault-0 -- vault operator unseal $VAULT_UNSEAL_KEY

# Need to join the other pods to the cluster
# Following
# https://developer.hashicorp.com/vault/tutorials/kubernetes/kubernetes-minikube-tls

# Touch the vault ready lock file
touch "${vaultreadylock}"