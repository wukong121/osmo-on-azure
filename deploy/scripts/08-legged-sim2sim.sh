#!/usr/bin/env bash
# Step 8: sim2sim validation at scale for a point-foot biped (MuJoCo + Gazebo/ROS 2, sharded on the CPU pool).
#   Usage: 08-legged-sim2sim.sh <step> [<step> ...]
#     seed        generate the scenario set and register the data asset
#                 (PROFILE=v1|v2, default v1; DATASET_VERSION, default 1)
#     import      register the exported policies as model versions (RL_TYPES, default "isaacgym isaaclab")
#     train       train a policy on a GPU pool and register it in AzureML (TRAIN_POOL, default
#                 onprem-h100; TRAIN_PLATFORM, default gpu; e.g. LEGGED_SET="max_iterations=3000";
#                 TRAIN_FROM_WORKFLOW=<id> only registers the train output of that workflow)
#     image       build the Gazebo (ROS 2) image in the cluster and push it to the private ACR
#                 (GAZEBO_IMAGE_TAG, default v1)
#     validate    candidate (+ current production model) on the latest scenario set; promote if better
#                 (MODELS=<name>:<version>, default pointfoot-policy:1)
#     revalidate  every registered model version on the latest scenario set; no promotion
#     campaign    hybrid run across pools: shard ranges per pool in CAMPAIGN, e.g. (default)
#                 "ext-sg:mujoco=0:5 onprem-h100:mujoco=5:10 default:gazebo=0:8"; each pool publishes
#                 its shard results to the data lake, then the gate runs in Azure (MODELS as validate,
#                 or <name>:all to re-validate)
#   Common: DATASET=<name>[:<version>], SHARDS (MuJoCo, default 10), GAZEBO_SHARDS (default 8 when the
#     ACR exists, 0 = MuJoCo only), GAZEBO_IMAGE_TAG; extra --set values through LEGGED_SET,
#     e.g. LEGGED_SET="max_fall_rate=0.1" 08-legged-sim2sim.sh validate
#
# Robot and policy sources (git repositories) come from deploy/scripts/legged.env (not committed;
# see legged.env.example) or the environment:
#   ROBOT_DESCRIPTION_REPO, ROBOT_PATH   MJCF at <ROBOT_PATH>/xml/robot.xml, meshes at <ROBOT_PATH>/meshes
#   POLICY_REPO, POLICY_PATH             params.yaml + policy/<rl_type>/{policy,encoder}.onnx
#   ROBOT_TYPE                           label recorded on the data asset and model versions
#   SDK_REPO, GAZEBO_REPO, CONTROLLER_REPO   vendor low-level SDK, Gazebo hardware plugin and ROS 2
#                                        RL controller, built into the Gazebo image
# Prerequisite: the AzureML resources in infra/terraform/azureml.tf are applied.
source "$(dirname "$0")/lib.sh"
[[ -f "$(dirname "$0")/legged.env" ]] && source "$(dirname "$0")/legged.env"
require jq osmo
(( $# )) || fatal "usage: $0 seed|import|train|image|validate|revalidate|campaign ..."
load_tf_outputs
aks_login
start_port_forward
osmo_admin_login

AML_WORKSPACE="$(tf_out aml_workspace_name)"
AML_DATASTORE="$(tf_out data_lake_datastore_name)"
AML_SUBSCRIPTION_ID="$(tf_out aml_workspace_id | cut -d/ -f3)"
AML_SET=(aml_subscription_id="$AML_SUBSCRIPTION_ID" aml_resource_group="$RG" aml_workspace="$AML_WORKSPACE")
DATASET="${DATASET:-pointfoot-sim2sim-scenarios}"
ACR="$(tf_out acr_login_server 2>/dev/null || true)"
GAZEBO_IMAGE="${ACR:+$ACR/legged-gazebo-ros2:${GAZEBO_IMAGE_TAG:-v1}}"
GAZEBO_SHARDS="${GAZEBO_SHARDS:-$([[ -n "$ACR" ]] && echo 8 || echo 0)}"
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
    train)
      for v in TRAIN_REPO TRAIN_TASK ROBOT_TYPE POLICY_REPO POLICY_PATH; do
        [[ -n "${!v:-}" ]] || fatal "$v is not set (see deploy/scripts/legged.env.example)"
      done
      tpool="${TRAIN_POOL:-onprem-h100}"
      info "Training on pool $tpool (platform ${TRAIN_PLATFORM:-gpu})"
      POOL="$tpool" run_workflow "$WORKFLOWS_DIR/legged-train.yaml" 21600 --set-string "${AML_SET[@]}" \
        train_repo="$TRAIN_REPO" task="$TRAIN_TASK" robot_type="$ROBOT_TYPE" \
        policy_repo="$POLICY_REPO" policy_path="$POLICY_PATH" train_platform="${TRAIN_PLATFORM:-gpu}" \
        pool_label="$tpool" from_workflow="${TRAIN_FROM_WORKFLOW:-}" "${set_extra[@]}" ;;
    image)
      [[ -n "$ACR" ]] || fatal "no ACR (apply infra/terraform with acr_enabled = true)"
      for v in ROBOT_DESCRIPTION_REPO SDK_REPO GAZEBO_REPO CONTROLLER_REPO; do
        [[ -n "${!v:-}" ]] || fatal "$v is not set (see deploy/scripts/legged.env.example)"
      done
      run_workflow "$WORKFLOWS_DIR/build-image.yaml" 5400 --set-string registry="$ACR" \
        image="legged-gazebo-ros2:${GAZEBO_IMAGE_TAG:-v1}" dockerfile=../images/legged-gazebo-ros2/Dockerfile \
        build_args="ROBOT_DESCRIPTION_REPO=$ROBOT_DESCRIPTION_REPO SDK_REPO=$SDK_REPO GAZEBO_REPO=$GAZEBO_REPO CONTROLLER_REPO=$CONTROLLER_REPO" ;;
    validate|revalidate)
      if [[ "$s" == validate ]]; then models="${MODELS:-pointfoot-policy:1}"; mode=promote
      else models="${MODELS:-pointfoot-policy}"; models="${models%%:*}:all"; mode=revalidate; fi
      info "MuJoCo shards: ${SHARDS:-10}; Gazebo shards: $GAZEBO_SHARDS ${GAZEBO_IMAGE:+($GAZEBO_IMAGE)}"
      run_workflow "$WORKFLOWS_DIR/legged-validate.yaml" 7200 --set-string "${AML_SET[@]}" \
        models="$models" dataset="$DATASET" mode="$mode" gazebo_image="$GAZEBO_IMAGE" \
        --set shards="${SHARDS:-10}" gazebo_shards="$GAZEBO_SHARDS" "${extra[@]}" ;;
    campaign)
      # Hybrid run: shard workflows in several pools publish to the data lake; the gate runs in Azure
      models="${MODELS:-pointfoot-policy:1}"; mode="${MODE:-promote}"
      [[ "$models" == *:all ]] && mode=revalidate
      run_id="run-$(date -u +%Y%m%d-%H%M%S)"
      spec="${CAMPAIGN:-ext-sg:mujoco=0:5 onprem-h100:mujoco=5:10 default:gazebo=0:8}"
      m_total=0; g_total=0
      for part in $spec; do
        rs="${part#*:}"
        for r in ${rs//,/ }; do
          kind="${r%%=*}"; to="${r##*:}"
          [[ "$kind" == mujoco ]] && (( to > m_total )) && m_total=$to
          [[ "$kind" == gazebo ]] && (( to > g_total )) && g_total=$to
        done
      done
      info "Campaign $run_id: models $models ($mode); MuJoCo shards $m_total, Gazebo shards $g_total; $spec"
      pids=()
      for part in $spec; do
        pool="${part%%:*}"; ranges=(mujoco_from=0 mujoco_to=0 gazebo_from=0 gazebo_to=0)
        IFS=',' read -ra items <<< "${part#*:}"
        for r in "${items[@]}"; do
          kind="${r%%=*}"; range="${r#*=}"
          ranges+=("${kind}_from=${range%%:*}" "${kind}_to=${range##*:}")
        done
        (POOL="$pool" run_workflow "$WORKFLOWS_DIR/legged-validate.yaml" 10800 --set-string "${AML_SET[@]}" \
          models="$models" dataset="$DATASET" mode="$mode" gazebo_image="$GAZEBO_IMAGE" stage=shards \
          run_id="$run_id" pool_label="$pool" \
          --set shards="$m_total" gazebo_shards="$g_total" "${ranges[@]}" "${extra[@]}" \
          > "/tmp/${run_id}-${pool}.log" 2>&1; echo "$?" > "/tmp/${run_id}-${pool}.rc") &
        pids+=($!)
        info "  pool $pool: ${part#*:} (log /tmp/${run_id}-${pool}.log)"
      done
      wait "${pids[@]}"
      for part in $spec; do
        pool="${part%%:*}"; rc="$(cat "/tmp/${run_id}-${pool}.rc")"
        grep -E "workflow:|COMPLETED|ended in" "/tmp/${run_id}-${pool}.log" | sed "s/^/  [$pool] /"
        [[ "$rc" == 0 ]] || fatal "shards in pool $pool failed (see /tmp/${run_id}-${pool}.log)"
      done
      POOL=default run_workflow "$WORKFLOWS_DIR/legged-validate.yaml" 3600 --set-string "${AML_SET[@]}" \
        models="$models" dataset="$DATASET" mode="$mode" stage=gate run_id="$run_id" \
        --set shards="$m_total" gazebo_shards="$g_total" "${extra[@]}" ;;
    *) fatal "unknown step: $s" ;;
  esac
done
ok "Open AzureML Studio: https://ml.azure.com/ (workspace $AML_WORKSPACE) -> Jobs (experiment pointfoot-sim2sim) / Models / Data"
