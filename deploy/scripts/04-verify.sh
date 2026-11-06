#!/usr/bin/env bash
# Step 4: phase-1 acceptance checks. Submits the workflows in deploy/workflows and waits for each.
#   Usage: 04-verify.sh [hello|storage|gpu|isaaclab|mujoco|gazebo ...]   (default: hello storage gpu)
#   Simulation samples: 04-verify.sh isaaclab mujoco gazebo
source "$(dirname "$0")/lib.sh"
require jq osmo
load_tf_outputs
aks_login
start_port_forward
osmo_admin_login

# Backend must be online before submitting
online="$(osmo config show BACKEND default 2>/dev/null | sed -n '/^{/,/^}/p' | jq -r '.online // empty' || true)"
[[ "$online" == "true" ]] || warn "Backend 'default' does not report online=true (got: ${online:-unknown})"
osmo pool list || true

declare -A SPEC=( [hello]=hello.yaml [storage]=storage-roundtrip.yaml [gpu]=gpu-t4.yaml [isaaclab]=isaaclab-cartpole.yaml [mujoco]=mujoco-sim.yaml [gazebo]=gazebo-sim.yaml )
# GPU timeout covers Spot node scale-up from zero + driver install (~10-15 min)
declare -A TIMEOUT=( [hello]=600 [storage]=900 [gpu]=2400 [isaaclab]=2400 [mujoco]=900 [gazebo]=900 )

checks=("$@"); [[ $# -eq 0 ]] && checks=(hello storage gpu)

failed=0
for c in "${checks[@]}"; do
  [[ -n "${SPEC[$c]:-}" ]] || fatal "unknown check: $c"
  run_workflow "$WORKFLOWS_DIR/${SPEC[$c]}" "${TIMEOUT[$c]}" || failed=1
done
(( failed == 0 )) && ok "All checks passed" || fatal "Some checks failed"
