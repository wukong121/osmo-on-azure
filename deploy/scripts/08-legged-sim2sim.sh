#!/usr/bin/env bash
# Step 8: sim2sim validation at scale for a point-foot biped (MuJoCo, sharded on the CPU pool).
#   Usage: 08-legged-sim2sim.sh <step> [<step> ...]
#     seed        generate the scenario set and register the data asset
#                 (PROFILE=v1|v2, default v1; DATASET_VERSION, default 1)
#     import      register the exported policies as model versions (RL_TYPES, default "isaacgym isaaclab")
#     validate    candidate (+ current production model) on the latest scenario set; promote if better
#                 (MODELS=<name>:<version>, default pointfoot-policy:1)
#     revalidate  every registered model version on the latest scenario set; no promotion
#   Common: DATASET=<name>[:<version>], SHARDS (default 10); extra --set values through LEGGED_SET,
#     e.g. LEGGED_SET="max_fall_rate=0.1" 08-legged-sim2sim.sh validate
#
# Robot and policy sources (git repositories) come from deploy/scripts/legged.env (not committed;
# see legged.env.example) or the environment:
#   ROBOT_DESCRIPTION_REPO, ROBOT_PATH   MJCF at <ROBOT_PATH>/xml/robot.xml, meshes at <ROBOT_PATH>/meshes
#   POLICY_REPO, POLICY_PATH             params.yaml + policy/<rl_type>/{policy,encoder}.onnx
#   ROBOT_TYPE                           label recorded on the data asset and model versions
# Prerequisite: the AzureML resources in infra/terraform/azureml.tf are applied.
source "$(dirname "$0")/lib.sh"
[[ -f "$(dirname "$0")/legged.env" ]] && source "$(dirname "$0")/legged.env"
require jq osmo
(( $# )) || fatal "usage: $0 seed|import|validate|revalidate ..."
load_tf_outputs
aks_login
start_port_forward
osmo_admin_login

AML_WORKSPACE="$(tf_out aml_workspace_name)"
AML_DATASTORE="$(tf_out data_lake_datastore_name)"
AML_SUBSCRIPTION_ID="$(tf_out aml_workspace_id | cut -d/ -f3)"
AML_SET=(aml_subscription_id="$AML_SUBSCRIPTION_ID" aml_resource_group="$RG" aml_workspace="$AML_WORKSPACE")
DATASET="${DATASET:-pointfoot-sim2sim-scenarios}"
info "AzureML workspace: $AML_WORKSPACE (resource group $RG)"
# shellcheck disable=SC2206
extra=(${LEGGED_SET:-})
set_extra=(); (( ${#extra[@]} )) && set_extra=(--set "${extra[@]}")

seed_set() {
  local v
  for v in ROBOT_TYPE ROBOT_DESCRIPTION_REPO ROBOT_PATH POLICY_REPO POLICY_PATH; do
    [[ -n "${!v:-}" ]] || fatal "$v is not set (see deploy/scripts/legged.env.example)"
  done
  SEED_SET=("${AML_SET[@]}" aml_datastore="$AML_DATASTORE" robot_type="$ROBOT_TYPE"
    robot_description_repo="$ROBOT_DESCRIPTION_REPO" robot_path="$ROBOT_PATH"
    policy_repo="$POLICY_REPO" policy_path="$POLICY_PATH" rl_types="${RL_TYPES:-isaacgym isaaclab}"
    dataset="${DATASET%%:*}" dataset_version="${DATASET_VERSION:-1}" profile="${PROFILE:-v1}")
}

for s in "$@"; do
  case "$s" in
    seed|import)
      seed_set
      if [[ "$s" == seed ]]; then toggles=(seed_data=true import_policies=false); else toggles=(seed_data=false import_policies=true); fi
      run_workflow "$WORKFLOWS_DIR/legged-seed.yaml" 1200 --set-string "${SEED_SET[@]}" "${toggles[@]}" "${set_extra[@]}" ;;
    validate|revalidate)
      if [[ "$s" == validate ]]; then models="${MODELS:-pointfoot-policy:1}"; mode=promote
      else models="${MODELS:-pointfoot-policy}"; models="${models%%:*}:all"; mode=revalidate; fi
      run_workflow "$WORKFLOWS_DIR/legged-validate.yaml" 3600 --set-string "${AML_SET[@]}" \
        models="$models" dataset="$DATASET" mode="$mode" --set shards="${SHARDS:-10}" "${extra[@]}" ;;
    *) fatal "unknown step: $s" ;;
  esac
done
ok "Open AzureML Studio: https://ml.azure.com/ (workspace $AML_WORKSPACE) -> Jobs (experiment pointfoot-sim2sim) / Models / Data"
