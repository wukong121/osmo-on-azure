#!/usr/bin/env bash
# Resume the environment after it was stopped (e.g. by a subscription's nightly auto-shutdown).
#
# - Starts AKS and PostgreSQL if they are stopped
# - Restarts pods that failed to be created while the Workload Identity webhook was not ready
#   ("failed calling webhook mutation.azure-workload-identity.io")
# - Restarts Envoy so it reloads its listener and clusters in one pass
source "$(dirname "$0")/lib.sh"
require az jq
load_tf_outputs
PG_NAME="${PG_FQDN%%.*}"

if [[ "$(az aks show -g "$RG" -n "$AKS" --query powerState.code -o tsv)" != "Running" ]]; then
  info "Starting AKS $AKS"; az aks start -g "$RG" -n "$AKS" -o none
fi
if [[ "$(az postgres flexible-server show -g "$RG" -n "$PG_NAME" --query state -o tsv)" != "Ready" ]]; then
  info "Starting PostgreSQL $PG_NAME"; az postgres flexible-server start -g "$RG" -n "$PG_NAME" -o none
fi
aks_login

info "Waiting for the Workload Identity webhook"
kubectl rollout status deploy/azure-wi-webhook-controller-manager -n kube-system --timeout=5m >/dev/null

info "Restarting OSMO components"
kubectl rollout restart deploy -n "$NS_OSMO" >/dev/null
kubectl rollout status deploy -n "$NS_OSMO" --timeout=10m >/dev/null
kubectl rollout restart deploy -n "$NS_OPERATOR" >/dev/null
kubectl rollout status deploy -n "$NS_OPERATOR" --timeout=5m >/dev/null
kubectl get pods -n "$NS_OSMO"
ok "Environment resumed. Backend status: osmo config show BACKEND default"
