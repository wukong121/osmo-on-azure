#!/usr/bin/env bash
# Install (or reconfigure) a single-node k3s cluster that joins OSMO as an external compute backend
# (another cloud's Kubernetes or an on-prem server). Run ON the external host as a sudo-capable user:
#
#   k3s-node.sh <cluster-name> <oidc-base-url> [--gpu] [--data-dir DIR]
#
#   cluster-name   backend / node name, e.g. ext-sg, onprem-h100
#   oidc-base-url  public HTTPS base where this cluster's OIDC discovery documents are published
#                  (09-external-backend.sh serves them from the OSMO ingress): the service-account
#                  issuer becomes <oidc-base-url>/<cluster-name>, which Entra ID trusts through a
#                  federated credential on the OSMO managed identity (infra/terraform/external.tf)
#   --gpu          use the NVIDIA container runtime by default and deploy the NVIDIA device plugin
#                  (needs the NVIDIA driver and nvidia-container-toolkit on the host)
#   --data-dir     k3s data directory (images can be large; default /var/lib/rancher/k3s); the kubelet
#                  root dir (pod ephemeral storage) goes to <data-dir>/kubelet
#
# The cluster only makes outbound connections (to OSMO, Entra ID, the registry and the storage
# gateway); nothing has to be opened inbound. kubectl/crictl symlinks are not created, so an
# existing kubectl on the host is left alone: use kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml.
set -euo pipefail

NAME="${1:?cluster name}"; OIDC_BASE="${2:?oidc base url}"; shift 2
GPU=false; DATA_DIR=/var/lib/rancher/k3s
while (( $# )); do
  case "$1" in
    --gpu) GPU=true ;;
    --data-dir) DATA_DIR="$2"; shift ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
  shift
done
ISSUER="${OIDC_BASE%/}/${NAME}"

sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<EOF
node-name: ${NAME}
data-dir: ${DATA_DIR}
write-kubeconfig-mode: "0644"
disable: [traefik, servicelb]
kube-apiserver-arg:
  - service-account-issuer=${ISSUER}
  - service-account-jwks-uri=${ISSUER}/openid/v1/jwks
# Pod ephemeral storage (emptyDir, container writable layers' logs) on the same disk as the data dir
kubelet-arg:
  - root-dir=${DATA_DIR}/kubelet
EOF
if $GPU; then
  echo "default-runtime: nvidia" | sudo tee -a /etc/rancher/k3s/config.yaml >/dev/null
fi

if command -v k3s >/dev/null 2>&1; then
  echo "k3s present: restarting with the new configuration"
  sudo systemctl restart k3s
else
  curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh
  sudo INSTALL_K3S_SYMLINK=skip sh /tmp/k3s-install.sh
fi

K="kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml"
command -v kubectl >/dev/null 2>&1 || K="sudo k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml"
for _ in $(seq 1 60); do $K get node "$NAME" >/dev/null 2>&1 && break; sleep 2; done
$K wait --for=condition=Ready "node/$NAME" --timeout=120s

if $GPU; then
  $K apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.4/deployments/static/nvidia-device-plugin.yml >/dev/null
fi
echo "issuer: $($K get --raw /.well-known/openid-configuration | python3 -c 'import json,sys; print(json.load(sys.stdin)["issuer"])')"
$K get nodes -o wide
