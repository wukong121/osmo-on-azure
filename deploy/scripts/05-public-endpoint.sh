#!/usr/bin/env bash
# Step 5 (optional): expose OSMO on a public HTTPS hostname with your own certificate, via Traefik.
#
#   OSMO_HOSTNAME=osmo.example.com \
#   TLS_CERT_FILE=/path/fullchain.pem TLS_KEY_FILE=/path/private.key \
#   deploy/scripts/05-public-endpoint.sh
#
# Afterwards create a DNS A record: OSMO_HOSTNAME -> the printed public IP
# (terraform output ingress_public_ip; fixed, managed by infra/terraform).
# Access is protected by OSMO authentication (token); the endpoint itself is open to the internet.
source "$(dirname "$0")/lib.sh"
require helm kubectl envsubst openssl jq
: "${OSMO_HOSTNAME:?set OSMO_HOSTNAME}" "${TLS_CERT_FILE:?set TLS_CERT_FILE}" "${TLS_KEY_FILE:?set TLS_KEY_FILE}"
TRAEFIK_CHART_VERSION="${TRAEFIK_CHART_VERSION:-42.3.0}"
load_tf_outputs

# The certificate must cover the hostname and match the key
openssl x509 -in "$TLS_CERT_FILE" -noout -checkhost "$OSMO_HOSTNAME" | grep -q 'does match' \
  || fatal "certificate does not cover $OSMO_HOSTNAME"
[[ "$(openssl x509 -in "$TLS_CERT_FILE" -noout -pubkey | sha256sum)" == \
   "$(openssl pkey -in "$TLS_KEY_FILE" -pubout 2>/dev/null | sha256sum)" ]] \
  || fatal "TLS_KEY_FILE does not match TLS_CERT_FILE"
aks_login

info "Installing Traefik (chart $TRAEFIK_CHART_VERSION)"
helm repo add traefik https://traefik.github.io/charts --force-update >/dev/null
# Use the static public IP managed by infra/terraform (stable across Traefik reinstalls)
INGRESS_PIP_NAME="$(tf_out ingress_public_ip_name)"
INGRESS_IP="$(tf_out ingress_public_ip)"
helm upgrade --install traefik traefik/traefik \
  --version "$TRAEFIK_CHART_VERSION" \
  --namespace traefik --create-namespace \
  -f "$VALUES_DIR/traefik.yaml" \
  --set-string "service.annotations.service\.beta\.kubernetes\.io/azure-load-balancer-resource-group=$RG" \
  --set-string "service.annotations.service\.beta\.kubernetes\.io/azure-pip-name=$INGRESS_PIP_NAME" \
  --wait --timeout 10m >/dev/null

info "Creating TLS Secret $NS_OSMO/osmo-public-tls"
kubectl create secret tls osmo-public-tls -n "$NS_OSMO" --cert="$TLS_CERT_FILE" --key="$TLS_KEY_FILE" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

info "Applying Ingress for $OSMO_HOSTNAME"
export OSMO_HOSTNAME
envsubst '${OSMO_HOSTNAME}' < "$DEPLOY_DIR/manifests/public-ingress.yaml" | kubectl apply -f - >/dev/null

# Wait until the cloud provider has moved the LoadBalancer onto the static IP
ip=""
for _ in $(seq 1 90); do
  ip="$(kubectl get svc traefik -n traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
  [[ "$ip" == "$INGRESS_IP" ]] && break
  sleep 5
done
[[ -n "$ip" ]] || fatal "Traefik LoadBalancer has no public IP yet: kubectl get svc traefik -n traefik"
[[ "$ip" == "$INGRESS_IP" ]] || warn "Traefik got $ip, expected the Terraform-managed IP $INGRESS_IP"
ok "Public endpoint ready: https://$OSMO_HOSTNAME  (create DNS A record -> $ip)"
