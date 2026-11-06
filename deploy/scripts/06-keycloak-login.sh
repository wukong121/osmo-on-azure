#!/usr/bin/env bash
# Step 6 (optional): browser/UI login through Keycloak (official Keycloak Operator), with OSMO
# roles per user. Requires step 5 (public HTTPS hostname via Traefik); Keycloak is served at
# https://<OSMO_HOSTNAME>/auth.
#
#   OSMO_HOSTNAME=osmo.example.com \
#   KEYCLOAK_ADMINS="alice@example.com" KEYCLOAK_USERS="bob@example.com carol@example.com" \
#   deploy/scripts/06-keycloak-login.sh
#
# - KEYCLOAK_ADMINS join group osmo-admins (OSMO role osmo-admin); KEYCLOAK_USERS join osmo-users.
# - Users are imported only when the realm is first created (Keycloak realm import does not update
#   existing realms). Afterwards manage users and groups in the Keycloak admin console.
# - Initial passwords are temporary (changed at first login). They are stored in Secret
#   keycloak/keycloak-osmo-secrets and written to ~/.osmo-keycloak-initial-passwords (mode 600).
# - The Keycloak bootstrap admin is in Secret keycloak/keycloak-initial-admin.
source "$(dirname "$0")/lib.sh"
require helm kubectl python3 openssl envsubst jq
: "${OSMO_HOSTNAME:?set OSMO_HOSTNAME}" "${KEYCLOAK_ADMINS:?set KEYCLOAK_ADMINS (space-separated emails)}"
KEYCLOAK_USERS="${KEYCLOAK_USERS:-}"
KEYCLOAK_VERSION="${KEYCLOAK_VERSION:-26.8.2}"
NS_KC="keycloak"
KC_DIR="$DEPLOY_DIR/manifests/keycloak"
OPERATOR_URL="https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KEYCLOAK_VERSION}/kubernetes"
python3 -c 'import yaml' 2>/dev/null || fatal "python3 module 'yaml' is required"
load_tf_outputs
PG_ADMIN_PASSWORD="$(tf_out postgres_admin_password)"
aks_login
ensure_ns "$NS_KC"

rand() { python3 -c 'import secrets; print(secrets.token_urlsafe(18))'; }

# 1. Database login "keycloak" with access to database "keycloak" only
kc_db_password="$(secret_value "$NS_KC" keycloak-db password)"
[[ -n "$kc_db_password" ]] || kc_db_password="$(rand)"
kubectl create secret generic keycloak-db -n "$NS_KC" \
  --from-literal=username=keycloak --from-file=password=<(printf '%s' "$kc_db_password") \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create secret generic keycloak-db-bootstrap -n "$NS_KC" \
  --from-literal=host="$PG_FQDN" --from-literal=user="$PG_USER" \
  --from-file=password=<(printf '%s' "$PG_ADMIN_PASSWORD") \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
unset PG_ADMIN_PASSWORD kc_db_password
info "Creating database login 'keycloak'"
kubectl delete job keycloak-db-init -n "$NS_KC" --ignore-not-found >/dev/null
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: keycloak-db-init
  namespace: keycloak
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: psql
          image: postgres:16-alpine
          env:
            - {name: PGHOST, valueFrom: {secretKeyRef: {name: keycloak-db-bootstrap, key: host}}}
            - {name: PGUSER, valueFrom: {secretKeyRef: {name: keycloak-db-bootstrap, key: user}}}
            - {name: PGPASSWORD, valueFrom: {secretKeyRef: {name: keycloak-db-bootstrap, key: password}}}
            - {name: KC_PASSWORD, valueFrom: {secretKeyRef: {name: keycloak-db, key: password}}}
            - {name: PGSSLMODE, value: require}
          command: ["sh", "-c"]
          args:
            - |
              set -e
              psql -v ON_ERROR_STOP=1 -d postgres -v kcpw="$KC_PASSWORD" <<'SQL'
              SELECT 'CREATE ROLE keycloak LOGIN' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'keycloak') \gexec
              ALTER ROLE keycloak WITH LOGIN PASSWORD :'kcpw';
              GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;
              SQL
              psql -v ON_ERROR_STOP=1 -d keycloak -c 'GRANT ALL ON SCHEMA public TO keycloak;'
              echo "database login keycloak ready"
          resources:
            requests: {cpu: 50m, memory: 64Mi}
            limits: {cpu: 500m, memory: 256Mi}
YAML
kubectl wait --for=condition=complete job/keycloak-db-init -n "$NS_KC" --timeout=5m >/dev/null \
  || { kubectl logs -n "$NS_KC" job/keycloak-db-init >&2 || true; fatal "database init job failed"; }
kubectl delete secret keycloak-db-bootstrap -n "$NS_KC" >/dev/null
ok "Database login 'keycloak' ready"

# 2. Keycloak Operator
info "Installing Keycloak Operator $KEYCLOAK_VERSION"
# All CRDs the operator watches (26.8 added OIDC/SAML client CRDs; it fails to start without them)
for crd in keycloaks keycloakrealmimports keycloakoidcclients keycloaksamlclients; do
  kubectl apply --server-side -f "$OPERATOR_URL/${crd}.k8s.keycloak.org-v1.yml" >/dev/null
done
kubectl apply -n "$NS_KC" -f "$OPERATOR_URL/kubernetes.yml" >/dev/null
kubectl rollout status deploy/keycloak-operator -n "$NS_KC" --timeout=5m >/dev/null
ok "Keycloak Operator ready"

# 3. Keycloak instance + public route (/auth)
export OSMO_HOSTNAME PG_FQDN
envsubst '${OSMO_HOSTNAME} ${PG_FQDN}' < "$KC_DIR/keycloak.yaml" | kubectl apply -f - >/dev/null
kubectl get secret osmo-public-tls -n "$NS_OSMO" -o json \
  | jq 'del(.metadata.namespace,.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.ownerReferences,.metadata.managedFields,.metadata.annotations)' \
  | kubectl apply -n "$NS_KC" -f - >/dev/null
envsubst '${OSMO_HOSTNAME}' < "$KC_DIR/ingress.yaml" | kubectl apply -f - >/dev/null
info "Waiting for Keycloak (first start takes a few minutes)"
kubectl wait --for=condition=Ready keycloak/keycloak -n "$NS_KC" --timeout=15m >/dev/null \
  || fatal "Keycloak is not ready: kubectl describe keycloak keycloak -n $NS_KC"
ok "Keycloak ready"

# 4. Realm "osmo" with client osmo-web, roles, groups and users (first creation only)
existing="$(kubectl get secret keycloak-osmo-secrets -n "$NS_KC" -o json 2>/dev/null || echo '{}')"
realm_out="$(EXISTING="$existing" ADMINS="$KEYCLOAK_ADMINS" USERS="$KEYCLOAK_USERS" HOST="$OSMO_HOSTNAME" \
  REALM_FILE="$KC_DIR/realm-osmo.yaml" python3 - <<'PY'
import base64, json, os, secrets, yaml
data = json.loads(os.environ["EXISTING"]).get("data", {})
get = lambda k: base64.b64decode(data[k]).decode() if k in data else None
secret = {"OSMO_WEB_CLIENT_SECRET": get("OSMO_WEB_CLIENT_SECRET") or secrets.token_urlsafe(32)}
text = open(os.environ["REALM_FILE"]).read().replace("${OSMO_HOSTNAME}", os.environ["HOST"])
realm = yaml.safe_load(text)
members = [(e, "osmo-admins") for e in os.environ["ADMINS"].split()] + \
          [(e, "osmo-users") for e in os.environ["USERS"].split()]
users, placeholders, passwords = [], {"OSMO_WEB_CLIENT_SECRET": {"secret": {"name": "keycloak-osmo-secrets", "key": "OSMO_WEB_CLIENT_SECRET"}}}, {}
for i, (email, group) in enumerate(members):
    key = "PW_" + "".join(c if c.isalnum() else "_" for c in email).upper()
    secret[key] = get(key) or secrets.token_urlsafe(12)
    passwords[email] = secret[key]
    local = email.split("@")[0]
    users.append({"username": email, "email": email, "emailVerified": True, "enabled": True,
                  "firstName": local, "lastName": "OSMO",
                  "credentials": [{"type": "password", "value": "${" + key + "}", "temporary": True}],
                  "groups": ["/" + group]})
    placeholders[key] = {"secret": {"name": "keycloak-osmo-secrets", "key": key}}
realm["users"] = users
import_cr = {"apiVersion": "k8s.keycloak.org/v2beta1", "kind": "KeycloakRealmImport",
             "metadata": {"name": "osmo-realm", "namespace": "keycloak"},
             "spec": {"keycloakCRName": "keycloak", "placeholders": placeholders, "realm": realm}}
secret_cr = {"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
             "metadata": {"name": "keycloak-osmo-secrets", "namespace": "keycloak"},
             "data": {k: base64.b64encode(v.encode()).decode() for k, v in secret.items()}}
print(json.dumps({"secret": secret_cr, "import": import_cr, "passwords": passwords,
                  "client_secret": secret["OSMO_WEB_CLIENT_SECRET"]}))
PY
)"
echo "$realm_out" | jq '.secret' | kubectl apply -f - >/dev/null
umask 077
echo "$realm_out" | jq -r '.passwords | to_entries[] | "\(.key)\t\(.value)"' > "$HOME/.osmo-keycloak-initial-passwords"
if kubectl get keycloakrealmimport osmo-realm -n "$NS_KC" >/dev/null 2>&1; then
  info "Realm import osmo-realm already exists; manage users in the Keycloak admin console"
else
  info "Importing realm 'osmo'"
  echo "$realm_out" | jq '.import' | kubectl apply -f - >/dev/null
  kubectl wait --for=condition=Done keycloakrealmimport/osmo-realm -n "$NS_KC" --timeout=10m >/dev/null \
    || fatal "realm import failed: kubectl describe keycloakrealmimport osmo-realm -n $NS_KC"
fi
for _ in $(seq 1 30); do
  curl -fsS --max-time 10 "https://$OSMO_HOSTNAME/auth/realms/osmo/.well-known/openid-configuration" >/dev/null 2>&1 && break
  sleep 5
done
curl -fsS --max-time 10 "https://$OSMO_HOSTNAME/auth/realms/osmo/.well-known/openid-configuration" >/dev/null \
  || fatal "realm osmo not reachable at https://$OSMO_HOSTNAME/auth/realms/osmo"
ok "Realm osmo ready; initial passwords in ~/.osmo-keycloak-initial-passwords"

# 5. oauth2-proxy credentials (client secret from the realm; cookie secret kept)
cookie_secret="$(secret_value "$NS_OSMO" oauth2-proxy-secrets cookie_secret)"
[[ -n "$cookie_secret" ]] || cookie_secret="$(python3 -c 'import base64,secrets;print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())')"
kubectl create secret generic oauth2-proxy-secrets -n "$NS_OSMO" \
  --from-file=client_secret=<(echo "$realm_out" | jq -j '.client_secret') \
  --from-file=cookie_secret=<(printf '%s' "$cookie_secret") \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
unset cookie_secret realm_out existing

# 6. Remove the earlier Dex setup if present
if kubectl get deploy dex -n "$NS_OSMO" >/dev/null 2>&1; then
  info "Removing Dex"
  helm uninstall dex -n "$NS_OSMO" >/dev/null || true
  kubectl delete secret dex-config dex-initial-passwords -n "$NS_OSMO" --ignore-not-found >/dev/null
  kubectl get crd -o name | grep 'dex.coreos.com' | xargs -r kubectl delete >/dev/null
  rm -f "$HOME/.osmo-dex-initial-passwords"
fi

# 7. OSMO with oauth2-proxy + Keycloak JWT provider
KEYCLOAK_HOSTNAME="$OSMO_HOSTNAME" "$(dirname "$0")/02-osmo-service.sh"
# oauth2-proxy reads the client/cookie secrets only at startup
kubectl rollout restart deploy/osmo-gateway-oauth2-proxy -n "$NS_OSMO" >/dev/null
kubectl rollout status deploy/osmo-gateway-oauth2-proxy -n "$NS_OSMO" --timeout=3m >/dev/null
ok "Browser login: https://$OSMO_HOSTNAME  (Keycloak admin console: https://$OSMO_HOSTNAME/auth/admin)"
