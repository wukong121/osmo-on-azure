#!/usr/bin/env bash
# Step 1: install cluster add-ons required by OSMO: NVIDIA GPU Operator and KAI Scheduler.
source "$(dirname "$0")/lib.sh"
require helm jq
load_tf_outputs
aks_login

info "Installing NVIDIA GPU Operator $GPU_OPERATOR_VERSION"
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia --force-update >/dev/null
helm upgrade --install gpu-operator nvidia/gpu-operator \
  --version "$GPU_OPERATOR_VERSION" \
  --namespace gpu-operator --create-namespace \
  -f "$VALUES_DIR/gpu-operator.yaml" \
  --wait --timeout 10m
ok "GPU Operator installed (driver DaemonSets start when a T4 node joins)"

info "Installing KAI Scheduler $KAI_SCHEDULER_VERSION"
helm upgrade --install kai-scheduler oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler \
  --version "$KAI_SCHEDULER_VERSION" \
  --namespace kai-scheduler --create-namespace \
  -f "$VALUES_DIR/kai-scheduler.yaml" \
  --wait --timeout 10m
ok "KAI Scheduler installed"
