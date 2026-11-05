#!/usr/bin/env bash
# Shared helpers for the OSMO deployment scripts. Source, do not execute.
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
TF_DIR="${TF_DIR:-$REPO_ROOT/infra/terraform}"
VALUES_DIR="$DEPLOY_DIR/values"
WORKFLOWS_DIR="$DEPLOY_DIR/workflows"

# Pinned versions (see deploy/README.md)
GPU_OPERATOR_VERSION="${GPU_OPERATOR_VERSION:-v26.7.2}"
KAI_SCHEDULER_VERSION="${KAI_SCHEDULER_VERSION:-v0.14.9}"
OSMO_CHART_VERSION="${OSMO_CHART_VERSION:-1.3.1}"

# Namespaces / release names. NS_OSMO and the backend-operator release name are tied to
# the Workload Identity federated credentials in infra/terraform (osmo_workload_identity_subjects).
NS_OSMO="osmo"
NS_OPERATOR="osmo-operator"
NS_WORKFLOWS="osmo-workflows"
OPERATOR_RELEASE="osmo-operator"

OSMO_LOCAL_PORT="${OSMO_LOCAL_PORT:-9000}"
OSMO_URL="http://127.0.0.1:${OSMO_LOCAL_PORT}"

info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
fatal() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

require() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || fatal "required command not found: $c"; done
}

# tf_out <name>: read a Terraform output
tf_out() { terraform -chdir="$TF_DIR" output -raw "$1"; }

load_tf_outputs() {
  require terraform
  info "Reading Terraform outputs from $TF_DIR"
  RG="$(tf_out resource_group_name)"
  AKS="$(tf_out aks_cluster_name)"
  OSMO_CLIENT_ID="$(tf_out osmo_identity_client_id)"
  PG_FQDN="$(tf_out postgres_fqdn)"
  PG_USER="$(tf_out postgres_admin_username)"
  REDIS_HOST="$(tf_out redis_hostname)"
  STORAGE_ACCOUNT="$(tf_out storage_account_name)"
  STORAGE_CONTAINER="$(tf_out storage_container_name)"
}

# Fetch kubeconfig for the AKS cluster (Entra ID; local accounts are disabled)
aks_login() {
  require az kubectl kubelogin
  info "Fetching credentials for AKS cluster $AKS"
  az aks get-credentials -g "$RG" -n "$AKS" --overwrite-existing --only-show-errors >/dev/null
  kubelogin convert-kubeconfig -l azurecli
  kubectl get nodes -o wide >/dev/null || fatal "cannot reach the AKS API server (is your IP in admin_ip_cidrs?)"
}

ensure_ns() { kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }

# apply_secret <namespace> <name> <key> <value>: create or update a generic Secret without echoing the value
apply_secret() {
  kubectl create secret generic "$2" -n "$1" --from-file="$3"=<(printf '%s' "$4") \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

secret_value() { kubectl get secret "$2" -n "$1" -o jsonpath="{.data.$3}" 2>/dev/null | base64 -d; }

# Port-forward the OSMO gateway to localhost in the background; stopped on exit.
PF_PID=""
start_port_forward() {
  info "Port-forwarding osmo-gateway to $OSMO_URL"
  kubectl port-forward -n "$NS_OSMO" svc/osmo-gateway "${OSMO_LOCAL_PORT}:80" >/tmp/osmo-port-forward.log 2>&1 &
  PF_PID=$!
  trap 'stop_port_forward' EXIT
  local i
  for i in $(seq 1 30); do
    curl -fsS "$OSMO_URL/api/version" >/dev/null 2>&1 && { ok "Gateway reachable"; return 0; }
    sleep 2
  done
  fatal "gateway did not become reachable; see /tmp/osmo-port-forward.log"
}
stop_port_forward() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true; }

# Log in to OSMO with the default admin access token
osmo_admin_login() {
  require osmo
  local token
  token="$(secret_value "$NS_OSMO" osmo-default-admin password)"
  [[ -n "$token" ]] || fatal "Secret $NS_OSMO/osmo-default-admin not found; run 02-osmo-service.sh first"
  osmo login "$OSMO_URL" --method token --token-file <(printf "%s" "$token") >/dev/null
  ok "Logged in to OSMO as admin"
}
