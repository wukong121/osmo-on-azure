#!/usr/bin/env bash
# Step 4: phase-1 acceptance checks. Submits the workflows in deploy/workflows and waits for each.
#   Usage: 04-verify.sh [hello|storage|gpu|isaaclab ...]   (default: hello storage gpu)
source "$(dirname "$0")/lib.sh"
require jq osmo
load_tf_outputs
aks_login
start_port_forward
osmo_admin_login

POOL="${POOL:-default}"
POLL_INTERVAL=10

# Backend must be online before submitting
online="$(osmo config show BACKEND default 2>/dev/null | sed -n '/^{/,/^}/p' | jq -r '.online // empty' || true)"
[[ "$online" == "true" ]] || warn "Backend 'default' does not report online=true (got: ${online:-unknown})"
osmo pool list || true

run_workflow() {
  local spec="$1" timeout="$2" out wf status=""
  info "Submitting $(basename "$spec") to pool $POOL"
  out="$(osmo workflow submit "$spec" --pool "$POOL" -t json 2>&1)" || { echo "$out" >&2; return 1; }
  wf="$(printf '%s\n' "$out" | sed -n '/^{/,/^}/p' | jq -r '.name // .id // .workflow_id // empty')"
  [[ -n "$wf" ]] || { echo "$out" >&2; fatal "could not parse workflow id"; }
  info "  workflow: $wf"
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    status="$(osmo workflow query "$wf" -t json 2>/dev/null | sed -n '/^{/,/^}/p' | jq -r '.status // .state // "UNKNOWN"')" || status="UNKNOWN"
    case "$status" in
      COMPLETED) ok "$wf COMPLETED"; osmo workflow logs "$wf" 2>/dev/null | tail -20 || true; return 0 ;;
      FAILED*|CANCELED|CANCELLED)
        warn "$wf ended in $status"
        osmo workflow events "$wf" >&2 || true
        osmo workflow logs "$wf" >&2 || true
        return 1 ;;
    esac
    sleep "$POLL_INTERVAL"
  done
  warn "$wf did not finish within ${timeout}s (last status: $status)"
  return 1
}

declare -A SPEC=( [hello]=hello.yaml [storage]=storage-roundtrip.yaml [gpu]=gpu-t4.yaml [isaaclab]=isaaclab-cartpole.yaml )
# GPU timeout covers Spot node scale-up from zero + driver install (~10-15 min)
declare -A TIMEOUT=( [hello]=600 [storage]=900 [gpu]=2400 [isaaclab]=2400 )

checks=("$@"); [[ $# -eq 0 ]] && checks=(hello storage gpu)

failed=0
for c in "${checks[@]}"; do
  [[ -n "${SPEC[$c]:-}" ]] || fatal "unknown check: $c"
  run_workflow "$WORKFLOWS_DIR/${SPEC[$c]}" "${TIMEOUT[$c]}" || failed=1
done
(( failed == 0 )) && ok "All checks passed" || fatal "Some checks failed"
