#!/usr/bin/env bash
# Step 7: closed loop with AzureML — data -> simulation training -> model registry -> sim2sim validation.
#   Usage: 07-azureml-loop.sh [seed] [loop]        (default: seed loop)
#     seed  upload the sim2sim validation set to the data lake and register the AzureML data asset
#           (deploy/workflows/azureml-seed-data.yaml; DATASET_VERSION, default 1)
#     loop  train on T4 -> register model in AzureML -> validate in MuJoCo
#           (deploy/workflows/rl-train-validate.yaml)
#   Extra settings for the loop can be passed through LOOP_SET, e.g.
#     LOOP_SET="max_iterations=50 threshold=0.95" 07-azureml-loop.sh loop
# Prerequisite: the AzureML resources in infra/terraform/azureml.tf are applied.
source "$(dirname "$0")/lib.sh"
require jq osmo
load_tf_outputs
aks_login
start_port_forward
osmo_admin_login

AML_WORKSPACE="$(tf_out aml_workspace_name)"
AML_DATASTORE="$(tf_out data_lake_datastore_name)"
AML_SUBSCRIPTION_ID="$(tf_out aml_workspace_id | cut -d/ -f3)"
AML_SET=(aml_subscription_id="$AML_SUBSCRIPTION_ID" aml_resource_group="$RG" aml_workspace="$AML_WORKSPACE")
info "AzureML workspace: $AML_WORKSPACE (resource group $RG)"

steps=("$@"); [[ $# -eq 0 ]] && steps=(seed loop)
for s in "${steps[@]}"; do
  case "$s" in
    seed)
      run_workflow "$WORKFLOWS_DIR/azureml-seed-data.yaml" 900 \
        --set-string "${AML_SET[@]}" aml_datastore="$AML_DATASTORE" dataset_version="${DATASET_VERSION:-1}" ;;
    loop)
      # shellcheck disable=SC2206
      extra=(${LOOP_SET:-})
      if (( ${#extra[@]} )); then
        run_workflow "$WORKFLOWS_DIR/rl-train-validate.yaml" 3600 --set-string "${AML_SET[@]}" --set "${extra[@]}"
      else
        run_workflow "$WORKFLOWS_DIR/rl-train-validate.yaml" 3600 --set-string "${AML_SET[@]}"
      fi ;;
    *) fatal "unknown step: $s" ;;
  esac
done
ok "Open AzureML Studio: https://ml.azure.com/ (workspace $AML_WORKSPACE) -> Jobs / Models / Data"
