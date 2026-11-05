#!/usr/bin/env bash
# Step 3: register the AKS cluster as the OSMO backend "default" (osmo/backend-operator chart).
source "$(dirname "$0")/lib.sh"
require helm jq osmo
load_tf_outputs
aks_login
ensure_ns "$NS_OPERATOR"
ensure_ns "$NS_WORKFLOWS"

# ServiceAccount for workflow pods (pod template azure_workload_identity), federated in Terraform
kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: osmo-workflow
  namespace: ${NS_WORKFLOWS}
  annotations:
    azure.workload.identity/client-id: "${OSMO_CLIENT_ID}"
YAML
ok "ServiceAccount $NS_WORKFLOWS/osmo-workflow ready"

# Backend operator token (user backend-operator, role osmo-backend). Created once; delete the
# Secret to rotate.
if [[ -z "$(secret_value "$NS_OPERATOR" osmo-operator-token token)" ]]; then
  start_port_forward
  osmo_admin_login
  osmo user create backend-operator --roles osmo-backend >/dev/null 2>&1 \
    || info "User backend-operator already exists"
  expires="$(date -u -d '+365 days' +%Y-%m-%d)"
  token="$(osmo token set "backend-token-$(date -u +%Y%m%d%H%M)" \
    --user backend-operator --roles osmo-backend --expires-at "$expires" \
    --description "OSMO backend operator" -t json | sed -n '/^{/,/^}/p' | jq -r '.token')"
  [[ -n "$token" && "$token" != "null" ]] || fatal "failed to create backend operator token"
  apply_secret "$NS_OPERATOR" osmo-operator-token token "$token"
  unset token
  ok "Backend operator token stored in $NS_OPERATOR/osmo-operator-token (expires $expires)"
fi

info "Deploying OSMO backend-operator chart $OSMO_CHART_VERSION"
helm repo add osmo https://helm.ngc.nvidia.com/nvidia/osmo --force-update >/dev/null
helm upgrade --install "$OPERATOR_RELEASE" osmo/backend-operator \
  --version "$OSMO_CHART_VERSION" \
  --namespace "$NS_OPERATOR" \
  -f "$VALUES_DIR/osmo-backend-operator.yaml" \
  --set-string "serviceAccount.annotations.azure\.workload\.identity/client-id=$OSMO_CLIENT_ID" \
  --wait --timeout 10m

kubectl get pods -n "$NS_OPERATOR"
ok "Backend operator deployed. Check: osmo config show BACKEND default (online: true), osmo pool list"
