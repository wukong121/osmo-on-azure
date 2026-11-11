#!/usr/bin/env bash
# Step 2: deploy the OSMO control plane (osmo/service chart) wired to the Azure data services.
source "$(dirname "$0")/lib.sh"
require helm jq python3 openssl envsubst
load_tf_outputs
aks_login
ensure_ns "$NS_OSMO"

# Key Vault is private-only (some subscriptions enforce this by policy), so the credentials come
# from Terraform's sensitive outputs instead.
info "Creating database and Redis Secrets from Terraform outputs"
pg_password="$(tf_out postgres_admin_password)"
redis_key="$(tf_out redis_primary_key)"
apply_secret "$NS_OSMO" db-secret db-password "$pg_password"
apply_secret "$NS_OSMO" redis-secret redis-password "$redis_key"
unset pg_password redis_key

# Default admin access token: 43-char URL-safe token (OSMO requires exactly this length).
# Created once and kept; delete the Secret to rotate.
if [[ -z "$(secret_value "$NS_OSMO" osmo-default-admin password)" ]]; then
  info "Generating default admin access token"
  apply_secret "$NS_OSMO" osmo-default-admin password "$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
fi

# Master encryption key (MEK) for secrets stored in PostgreSQL. Created once; never overwritten,
# because replacing it makes existing encrypted data unreadable.
if ! kubectl get configmap mek-config -n "$NS_OSMO" >/dev/null 2>&1; then
  info "Generating master encryption key (MEK)"
  jwk="{\"k\":\"$(openssl rand -base64 32 | tr -d '\n')\",\"kid\":\"key1\",\"kty\":\"oct\"}"
  kubectl create configmap mek-config -n "$NS_OSMO" \
    --from-file=mek.yaml=<(printf 'currentMek: key1\nmeks:\n  key1: %s\n' "$(printf '%s' "$jwk" | base64 -w0)") \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  unset jwk
  warn "Back up the MEK: kubectl get configmap mek-config -n $NS_OSMO -o yaml > mek-backup.yaml (keep it out of git)"
fi

# OSMO 6.3.1 workaround: workflow_data uses a rotating user delegation SAS (see the manifest header).
info "Deploying workflow-data SAS rotator"
export OSMO_CLIENT_ID STORAGE_ACCOUNT STORAGE_CONTAINER
envsubst '${OSMO_CLIENT_ID} ${STORAGE_ACCOUNT} ${STORAGE_CONTAINER}' \
  < "$DEPLOY_DIR/manifests/workflow-data-sas-rotator.yaml" | kubectl apply -f - >/dev/null
if [[ -z "$(secret_value "$NS_OSMO" osmo-workflow-data-cred access_key)" ]]; then
  info "Generating the first SAS credential"
  job="osmo-sas-rotator-init-$(date +%s)"
  kubectl create job "$job" -n "$NS_OSMO" --from=cronjob/osmo-sas-rotator >/dev/null
  kubectl wait --for=condition=complete "job/$job" -n "$NS_OSMO" --timeout=5m >/dev/null \
    || { kubectl logs -n "$NS_OSMO" "job/$job" >&2 || true; fatal "SAS rotator job failed"; }
  ok "Secret osmo-workflow-data-cred created"
fi

endpoint="azure://${STORAGE_ACCOUNT}/${STORAGE_CONTAINER}"

# Private ACR (optional, infra/terraform/acr.tf): AKS pulls with its kubelet identity (AcrPull).
# OSMO checks at submit time that it can read the image manifest, which it cannot do for a
# private registry without stored credentials; skip that check for our registry instead of
# storing a password in OSMO.
acr_values=()
ACR_HOST="$(tf_out acr_login_server 2>/dev/null || true)"
if [[ -n "$ACR_HOST" ]]; then
  acr_values=(--set-json "services.configs.workflow.credential_config.disable_registry_validation=[\"$ACR_HOST\"]")
  info "Private registry $ACR_HOST: image pulls via the AKS kubelet identity"
fi

# Optional browser login: Keycloak (values/osmo-service-keycloak.yaml, set up by 06-keycloak-login.sh)
# or Entra ID (values/osmo-service-entra.yaml). Without either, OSMO is token-only (CLI).
extra_values=()
# Keep Keycloak login enabled on plain re-runs: detect an existing Keycloak from its Ingress
if [[ -z "${KEYCLOAK_HOSTNAME:-}" && -z "${ENTRA_CLIENT_ID:-}" ]] \
   && kubectl get keycloak keycloak -n keycloak >/dev/null 2>&1; then
  KEYCLOAK_HOSTNAME="$(kubectl get ingress keycloak -n keycloak -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"
  [[ -n "$KEYCLOAK_HOSTNAME" ]] && info "Detected Keycloak at https://$KEYCLOAK_HOSTNAME/auth; keeping browser login enabled"
fi
if [[ -n "${KEYCLOAK_HOSTNAME:-}" ]]; then
  [[ -n "$(secret_value "$NS_OSMO" oauth2-proxy-secrets client_secret)" ]] \
    || fatal "Secret $NS_OSMO/oauth2-proxy-secrets is missing; run 06-keycloak-login.sh"
  rendered="$(mktemp)"; trap 'rm -f "$rendered"' EXIT
  sed -e "s/OSMO_HOSTNAME/${KEYCLOAK_HOSTNAME}/g" "$VALUES_DIR/osmo-service-keycloak.yaml" > "$rendered"
  extra_values=(-f "$rendered")
  info "Keycloak login enabled (https://$KEYCLOAK_HOSTNAME/auth/realms/osmo)"
elif [[ -n "${ENTRA_CLIENT_ID:-}" ]]; then
  [[ -n "${ENTRA_TENANT_ID:-}" ]] || fatal "ENTRA_TENANT_ID is required with ENTRA_CLIENT_ID"
  [[ -n "$(secret_value "$NS_OSMO" oauth2-proxy-secrets client_secret)" ]] \
    || fatal "Secret $NS_OSMO/oauth2-proxy-secrets (client_secret, cookie_secret) is missing"
  rendered="$(mktemp)"; trap 'rm -f "$rendered"' EXIT
  sed -e "s/ENTRA_TENANT_ID/${ENTRA_TENANT_ID}/g" -e "s/ENTRA_CLIENT_ID/${ENTRA_CLIENT_ID}/g" \
    "$VALUES_DIR/osmo-service-entra.yaml" > "$rendered"
  extra_values=(-f "$rendered")
  info "Entra ID login enabled (client $ENTRA_CLIENT_ID)"
fi

info "Deploying OSMO service chart $OSMO_CHART_VERSION"
helm repo add osmo https://helm.ngc.nvidia.com/nvidia/osmo --force-update >/dev/null
helm upgrade --install osmo osmo/service \
  --version "$OSMO_CHART_VERSION" \
  --namespace "$NS_OSMO" \
  -f "$VALUES_DIR/osmo-service.yaml" \
  "${extra_values[@]}" "${acr_values[@]}" \
  --set-string "serviceAccount.annotations.azure\.workload\.identity/client-id=$OSMO_CLIENT_ID" \
  --set-string "services.postgres.serviceName=$PG_FQDN" \
  --set-string "services.postgres.user=$PG_USER" \
  --set-string "services.redis.serviceName=$REDIS_HOST" \
  --set-string "services.configs.workflow.workflow_data.base_url=https://${STORAGE_ACCOUNT}.blob.core.windows.net:443/${STORAGE_CONTAINER}" \
  --set-string "services.configs.workflow.workflow_log.credential.endpoint=${endpoint}/workflows/logs" \
  --set-string "services.configs.workflow.workflow_app.credential.endpoint=${endpoint}/apps" \
  --wait --timeout 15m

# Envoy reloads listeners (LDS) and clusters (CDS) from separate files; when a change adds or
# removes a cluster that a route references (e.g. toggling oauth2-proxy), the listener update can
# be rejected with "unknown cluster" and is not retried. Restart Envoy to load both in one pass.
kubectl rollout restart deploy/osmo-gateway-envoy -n "$NS_OSMO" >/dev/null
kubectl rollout status deploy/osmo-gateway-envoy -n "$NS_OSMO" --timeout=5m >/dev/null

kubectl get pods -n "$NS_OSMO"
ok "OSMO service deployed. Access: kubectl port-forward -n $NS_OSMO svc/osmo-gateway ${OSMO_LOCAL_PORT}:80"
