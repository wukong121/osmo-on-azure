#!/usr/bin/env bash
# Step 9 (optional): external compute backends (other clouds / on-prem) for OSMO.
#
#   09-external-backend.sh gateway
#       On AKS, once: the storage gateway and the OIDC document server.
#       - Storage gateway: Traefik TLS-passthrough routes on the public ingress (port 443), one per
#         storage endpoint (blob / dfs), matched by SNI, allow-listed to the external clusters'
#         egress IPs (Terraform output external_access_cidrs), forwarded to the private endpoints.
#         The storage accounts stay private-only (a subscription policy may force that); TLS is
#         end to end with the storage service, and requests still need SAS / Entra ID tokens.
#       - OIDC documents: https://<osmo-host>/oidc/<cluster>/... so Entra ID can verify the
#         external clusters' service-account tokens (federated credentials in external.tf).
#
#   09-external-backend.sh join <name> <kubeconfig> [--gpu]
#       For each external cluster (installed with scripts/external/k3s-node.sh):
#       - publish its OIDC discovery document and JWKS through the OSMO ingress
#       - on the cluster: KAI Scheduler, Azure Workload Identity webhook, ServiceAccount
#         osmo-workflow (OSMO managed identity, federated), DNS overrides that send the storage
#         endpoints to the gateway, and the OSMO backend-operator connecting to the public OSMO URL
#         as backend <name>
#       The matching OSMO pool (values/osmo-service-external.yaml) is applied by 02-osmo-service.sh.
source "$(dirname "$0")/lib.sh"
require az jq kubectl helm osmo
CMD="${1:?usage: $0 gateway | join <name> <kubeconfig> [--gpu]}"
load_tf_outputs
aks_login

OSMO_HOST="$(kubectl get ingress osmo-public -n "$NS_OSMO" -o jsonpath='{.spec.rules[0].host}')"
[[ -n "$OSMO_HOST" ]] || fatal "public ingress osmo-public not found (run 05-public-endpoint.sh)"
INGRESS_IP="$(tf_out ingress_public_ip)"
mapfile -t EXT_CIDRS < <(terraform -chdir="$TF_DIR" output -json external_access_cidrs | jq -r '.[]')
(( ${#EXT_CIDRS[@]} )) || fatal "no external_access_cidrs (set external_backends_enabled = true and apply Terraform)"

# Storage private endpoints: "<fqdn> <private ip>" for every blob / dfs endpoint in the resource group
storage_endpoints() {
  local nic
  for nic in $(az network private-endpoint list -g "$RG" --query "[].networkInterfaces[0].id" -o tsv); do
    az network nic show --ids "$nic" \
      --query "ipConfigurations[].[privateLinkConnectionProperties.fqdns[0], privateIPAddress]" -o tsv
  done | awk '$1 ~ /\.(blob|dfs)\.core\.windows\.net$/'
}

gateway() {
  local fqdn ip name routes="" svcs=""
  while read -r fqdn ip; do
    name="sgw-$(echo "${fqdn%%.core.windows.net}" | tr '.' '-')"
    svcs+="---
apiVersion: v1
kind: Service
metadata: {name: ${name}, namespace: ${NS_OSMO}, labels: {app.kubernetes.io/part-of: storage-gateway}}
spec:
  ports: [{name: https, port: 443, targetPort: 443, protocol: TCP}]
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: ${name}
  namespace: ${NS_OSMO}
  labels: {kubernetes.io/service-name: ${name}, app.kubernetes.io/part-of: storage-gateway}
addressType: IPv4
ports: [{name: https, port: 443, protocol: TCP}]
endpoints: [{addresses: [\"${ip}\"], conditions: {ready: true, serving: true}}]
"
    routes+="    - match: HostSNI(\`${fqdn}\`)
      middlewares: [{name: external-backends-only}]
      services: [{name: ${name}, port: 443}]
"
    info "gateway route ${fqdn} -> ${ip}"
  done < <(storage_endpoints)
  [[ -n "$routes" ]] || fatal "no storage private endpoints found in $RG"

  kubectl apply -f - <<YAML
${svcs}---
apiVersion: traefik.io/v1alpha1
kind: MiddlewareTCP
metadata: {name: external-backends-only, namespace: ${NS_OSMO}}
spec:
  ipAllowList:
    sourceRange: [$(printf '"%s",' "${EXT_CIDRS[@]}" | sed 's/,$//')]
---
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata: {name: storage-gateway, namespace: ${NS_OSMO}}
spec:
  entryPoints: [websecure]
  routes:
${routes}  tls:
    passthrough: true
YAML

  # OIDC document server: /oidc/<cluster>/.well-known/openid-configuration and /oidc/<cluster>/openid/v1/jwks
  kubectl get configmap osmo-oidc-docs -n "$NS_OSMO" >/dev/null 2>&1 \
    || kubectl create configmap osmo-oidc-docs -n "$NS_OSMO" >/dev/null
  kubectl apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata: {name: osmo-oidc-nginx, namespace: ${NS_OSMO}}
data:
  default.conf: |
    server {
      listen 8080;
      default_type application/json;
      location ~ ^/oidc/([a-z0-9-]+)/\.well-known/openid-configuration$ { alias /docs/\$1.openid-configuration; }
      location ~ ^/oidc/([a-z0-9-]+)/openid/v1/jwks$ { alias /docs/\$1.jwks; }
      location / { return 404; }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: osmo-oidc, namespace: ${NS_OSMO}}
spec:
  replicas: 1
  selector: {matchLabels: {app: osmo-oidc}}
  template:
    metadata: {labels: {app: osmo-oidc}}
    spec:
      containers:
        - name: nginx
          image: nginxinc/nginx-unprivileged:1.29-alpine
          ports: [{containerPort: 8080}]
          resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {memory: 64Mi}}
          volumeMounts:
            - {name: conf, mountPath: /etc/nginx/conf.d}
            - {name: docs, mountPath: /docs}
      volumes:
        - {name: conf, configMap: {name: osmo-oidc-nginx}}
        - {name: docs, configMap: {name: osmo-oidc-docs}}
---
apiVersion: v1
kind: Service
metadata: {name: osmo-oidc, namespace: ${NS_OSMO}}
spec:
  selector: {app: osmo-oidc}
  ports: [{port: 80, targetPort: 8080}]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: osmo-oidc
  namespace: ${NS_OSMO}
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls: [{hosts: ["${OSMO_HOST}"], secretName: osmo-public-tls}]
  rules:
    - host: "${OSMO_HOST}"
      http:
        paths:
          - path: /oidc
            pathType: Prefix
            backend: {service: {name: osmo-oidc, port: {number: 80}}}
YAML
  ok "Storage gateway and OIDC server ready (allow-list: ${EXT_CIDRS[*]})"
}

join() {
  local name="${1:?name}" kcfg="${2:?kubeconfig}" gpu="${3:-}"
  local X=(kubectl --kubeconfig "$kcfg")
  local H=(helm --kubeconfig "$kcfg")
  "${X[@]}" get nodes >/dev/null || fatal "cannot reach cluster $name with $kcfg"

  # 1. OIDC documents of this cluster -> AKS
  local issuer tmp
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  "${X[@]}" get --raw /.well-known/openid-configuration > "$tmp/$name.openid-configuration"
  "${X[@]}" get --raw /openid/v1/jwks > "$tmp/$name.jwks"
  issuer="$(jq -r .issuer "$tmp/$name.openid-configuration")"
  [[ "$issuer" == "https://$OSMO_HOST/oidc/$name" ]] \
    || fatal "issuer of $name is $issuer, expected https://$OSMO_HOST/oidc/$name (see scripts/external/k3s-node.sh)"
  kubectl get configmap osmo-oidc-docs -n "$NS_OSMO" -o json \
    | jq --rawfile c "$tmp/$name.openid-configuration" --rawfile j "$tmp/$name.jwks" \
        --arg n "$name" '.data = ((.data // {}) + {($n + ".openid-configuration"): $c, ($n + ".jwks"): $j})
                         | del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields)' \
    | kubectl apply -f - >/dev/null
  for _ in $(seq 1 30); do
    curl -fsS "$issuer/.well-known/openid-configuration" 2>/dev/null | jq -e --arg i "$issuer" '.issuer == $i' >/dev/null && break
    sleep 5
  done
  curl -fsS "$issuer/.well-known/openid-configuration" | jq -e --arg i "$issuer" '.issuer == $i' >/dev/null \
    || fatal "OIDC documents of $name are not served at $issuer"
  ok "OIDC issuer published: $issuer"

  # 2. Add-ons on the external cluster
  "${H[@]}" upgrade --install kai-scheduler oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler \
    --version "$KAI_SCHEDULER_VERSION" --namespace kai-scheduler --create-namespace \
    -f "$VALUES_DIR/kai-scheduler.yaml" --wait --timeout 10m >/dev/null
  helm repo add azure-workload-identity https://azure.github.io/azure-workload-identity/charts --force-update >/dev/null
  "${H[@]}" upgrade --install workload-identity-webhook azure-workload-identity/workload-identity-webhook \
    --namespace azure-workload-identity-system --create-namespace \
    --set azureTenantID="$(tf_out tenant_id)" \
    --set resources.requests.cpu=100m --set resources.requests.memory=64Mi \
    --set resources.limits.cpu=1 --set resources.limits.memory=256Mi \
    --wait --timeout 10m >/dev/null
  # The chart defaults (100m CPU, 30Mi memory) are too tight: under load the webhook pages its own
  # binary in from disk, misses its 1 s probes and restarts, and pod creation fails while it is down
  ok "KAI Scheduler and Workload Identity webhook installed on $name"

  local ns
  for ns in "$NS_OPERATOR" "$NS_WORKFLOWS"; do
    "${X[@]}" create namespace "$ns" --dry-run=client -o yaml | "${X[@]}" apply -f - >/dev/null
  done
  "${X[@]}" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: osmo-workflow
  namespace: ${NS_WORKFLOWS}
  annotations:
    azure.workload.identity/client-id: "${OSMO_CLIENT_ID}"
YAML

  # 3. Storage endpoints resolve to the gateway. k3s CoreDNS imports coredns-custom *.server as
  #    extra server blocks (the main block already uses the hosts plugin, which may appear only once)
  local hosts=""
  while read -r fqdn _; do hosts+="        ${INGRESS_IP} ${fqdn}"$'\n'; done < <(storage_endpoints)
  "${X[@]}" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ConfigMap
metadata: {name: coredns-custom, namespace: kube-system}
data:
  osmo-storage.server: |
    blob.core.windows.net:53 dfs.core.windows.net:53 {
      hosts {
${hosts}        fallthrough
      }
      forward . /etc/resolv.conf
    }
YAML
  "${X[@]}" rollout restart deploy/coredns -n kube-system >/dev/null
  ok "Storage endpoints on $name resolve to the gateway $INGRESS_IP"

  # 4. OSMO backend-operator (token per backend; delete the Secret to rotate)
  if [[ -z "$("${X[@]}" get secret osmo-operator-token -n "$NS_OPERATOR" -o jsonpath='{.data.token}' 2>/dev/null)" ]]; then
    start_port_forward
    osmo_admin_login
    osmo user create backend-operator --roles osmo-backend >/dev/null 2>&1 || true
    local expires token
    expires="$(date -u -d '+365 days' +%Y-%m-%d)"
    token="$(osmo token set "backend-token-${name}-$(date -u +%Y%m%d%H%M)" \
      --user backend-operator --roles osmo-backend --expires-at "$expires" \
      --description "OSMO backend operator ($name)" -t json | sed -n '/^{/,/^}/p' | jq -r '.token')"
    [[ -n "$token" && "$token" != "null" ]] || fatal "failed to create backend operator token"
    "${X[@]}" create secret generic osmo-operator-token -n "$NS_OPERATOR" \
      --from-literal=token="$token" --dry-run=client -o yaml | "${X[@]}" apply -f - >/dev/null
    unset token
  fi
  helm repo add osmo https://helm.ngc.nvidia.com/nvidia/osmo --force-update >/dev/null
  "${H[@]}" upgrade --install "$OPERATOR_RELEASE" osmo/backend-operator \
    --version "$OSMO_CHART_VERSION" --namespace "$NS_OPERATOR" \
    -f "$VALUES_DIR/osmo-backend-operator.yaml" \
    --set-string global.serviceUrl="https://$OSMO_HOST" \
    --set-string global.backendName="$name" \
    --wait --timeout 10m >/dev/null
  "${X[@]}" get pods -n "$NS_OPERATOR"
  ok "Backend $name joined. Check: osmo config show BACKEND $name (online: true); pool: values/osmo-service-external.yaml"
}

case "$CMD" in
  gateway) gateway ;;
  join) shift; join "$@" ;;
  *) fatal "unknown command $CMD" ;;
esac
