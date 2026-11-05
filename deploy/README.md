# OSMO on Azure: OSMO deployment (Helm)

English | [简体中文](README.zh-CN.md)

This directory deploys NVIDIA OSMO 6.3.1 onto the AKS cluster created by [infra/terraform](../infra/terraform/README.md). It uses the Azure data services from the same Terraform state.

**Status (2026-11-05):** deployed in West US 3, and all phase-1 acceptance checks pass (`hello`, `storage`, `gpu`).

## Components and versions

| Component | Chart / version | Namespace | Notes |
|---|---|---|---|
| NVIDIA GPU Operator | `nvidia/gpu-operator` v26.7.2 | `gpu-operator` | Driver 595.91.07 on T4 nodes, container toolkit v1.20.1 (the chart default), nvidia as the containerd default runtime |
| KAI Scheduler | `oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler` v0.14.9 | `kai-scheduler` | The KAI line paired with OSMO 6.3.x. GPU runtimeClass injection is disabled. |
| OSMO service | `osmo/service` 1.3.1 (OSMO 6.3.1), release `osmo` | `osmo` | API, router, worker, logger, agent, UI, Envoy gateway, authz |
| OSMO backend operator | `osmo/backend-operator` 1.3.1, release `osmo-operator` | `osmo-operator` | Registers AKS as backend `default`. Workflow pods run in `osmo-workflows`. |
| Workflow-data SAS rotator | [manifests/workflow-data-sas-rotator.yaml](manifests/workflow-data-sas-rotator.yaml) | `osmo` | A CronJob that works around an OSMO 6.3.1 bug (see below). Remove it after upgrading to OSMO 6.4. |

## Phase-1 design

- **Authentication.** OSMO-issued tokens only:
  - oauth2-proxy is disabled.
  - authz is enabled, and the gateway validates OSMO JWTs and strips client-supplied identity headers.
  - The `admin` user logs in with an access token stored in the `osmo/osmo-default-admin` Secret.
  - The backend operator uses its own token with the `osmo-backend` role.
  - The web UI needs an identity provider for browser login, so phase 1 is CLI-first. Entra ID through oauth2-proxy comes next.
- **Access.** The gateway is a ClusterIP service. Reach it with `kubectl port-forward`, which goes through the Entra ID–protected AKS API.
- **Data services.**
  - PostgreSQL uses TLS (`sslmode=require` for authz).
  - Redis uses TLS on port 10000.
  - Credentials come from Terraform sensitive outputs and are written to Kubernetes Secrets when you run the script. Key Vault is private-only; some subscriptions enforce this by policy.
- **Storage.** Blob under `azure://<account>/osmo/...`, reachable only through a private endpoint, with no account keys.
  - `workflow_log` and `workflow_app` use Workload Identity. The control plane runs as ServiceAccount `osmo/osmo`.
  - `workflow_data` (task artifacts) uses a rotating, container-scoped **user delegation SAS**. The SAS is signed with Entra ID, not an account key. See the issues section below for why.
- **Pool `default`.**
  - Platform `default`: CPU-only tasks on the system node pool.
  - Platform `t4`: 1 × T4 per task on the Spot pool `npgput4`. It defaults to 4 CPU, 32 GiB memory and 50 GiB storage, and tolerates the `nvidia.com/gpu` and Spot taints.

## Prerequisites

- `infra/terraform` applied, with access to its state. Your egress IP must be in `admin_ip_cidrs`, because the scripts call the AKS API.
- Keep at least one GPU node while you test (`gpu_node_min_count = 1`). OSMO rejects submissions to a platform that has no nodes. See the issues section.
- Tools: `az` (signed in), `terraform`, `kubectl`, `kubelogin`, `helm` (v3 or v4), `jq`, `python3`, `openssl`, `envsubst`.
- The [OSMO CLI 6.3.1](https://github.com/NVIDIA/OSMO/releases/tag/6.3.1). It is needed for steps 3 and 4:

  ```bash
  curl -fsSLO https://github.com/NVIDIA/OSMO/releases/download/6.3.1/osmo-client-installer-6.3.1-linux-x86_64.sh
  bash osmo-client-installer-6.3.1-linux-x86_64.sh   # installs to /usr/local/osmo (uses sudo)
  ```

## Deploy

```bash
deploy/scripts/01-cluster-addons.sh   # GPU Operator + KAI Scheduler
deploy/scripts/02-osmo-service.sh     # Secrets, MEK, SAS rotator, OSMO service chart
deploy/scripts/03-osmo-backend.sh     # backend-operator token + chart; registers backend "default"
deploy/scripts/04-verify.sh           # phase-1 acceptance workflows
```

Every script can be re-run safely. Two values are created once and never overwritten:
- The default admin token (`osmo/osmo-default-admin`)
- The master encryption key (`osmo/mek-config`)

Back up the MEK. Losing it makes the encrypted data in PostgreSQL unreadable.

## Use OSMO

```bash
kubectl port-forward -n osmo svc/osmo-gateway 9000:80 &
osmo login http://127.0.0.1:9000 --method token \
  --token-file <(kubectl get secret osmo-default-admin -n osmo -o jsonpath='{.data.password}' | base64 -d)

osmo pool list
osmo workflow submit deploy/workflows/hello.yaml --pool default
osmo workflow logs <workflow-id>
```

## Phase-1 acceptance checks

`04-verify.sh` covers the stages of the [workflow sequence](../docs/images/osmo_workflow_sequence.svg):

| Check | Workflow | Stages covered | Result (2026-11-05) |
|---|---|---|---|
| `hello` | [hello.yaml](workflows/hello.yaml) | Token login, submit and queue, backend operator creates the pod, status, logs, completion | ✅ |
| `storage` | [storage-roundtrip.yaml](workflows/storage-roundtrip.yaml) | Artifact upload to Blob over the private endpoint, and download by a dependent task | ✅ |
| `gpu` | [gpu-t4.yaml](workflows/gpu-t4.yaml) | KAI scheduling onto the Spot T4 pool, GPU driver, `nvidia-smi` in the container (`Tesla T4, 595.91.07, 16384 MiB`) | ✅ |

The gateway was also checked directly:
- A request without a token returns 401.
- A request with forged `x-osmo-user` / `x-osmo-roles` headers also returns 401.
- The admin access token can be exchanged for an OSMO JWT.

Run a subset with `deploy/scripts/04-verify.sh hello storage`.

## Issues found during deployment and their fixes

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | Gateway port refuses connections. Envoy logs `RequiresAny ... must contain at least 2 item(s)` | `osmo/service` 1.3.1 always renders the catch-all JWT rule as `requires_any`, and Envoy rejects that with only one provider | The OSMO JWT provider is listed twice in [values/osmo-service.yaml](values/osmo-service.yaml). Replace the duplicate with Entra ID in phase 2. |
| 2 | CPU tasks are stuck in `Init` with `no runtime for "nvidia" is configured` | KAI's admission webhook adds `runtimeClassName: nvidia` to every pod that declares `nvidia.com/gpu`. OSMO's default template declares it even when the value is 0. | KAI `admission.gpuPodRuntimeClassName: ""`. On GPU nodes, nvidia is the containerd default runtime instead. |
| 3 | Worker logs `ClusterCrossSlotError` | Azure Managed Redis with `EnterpriseCluster` on a multi-shard SKU rejects multi-key pipelines | Redis `clustering_policy = "NoCluster"` (infra/terraform) |
| 4 | Task artifact upload fails with `KeyError: 'access_key_id'` | OSMO 6.3.1 bug: osmo-ctrl assumes the workflow_data credential has keys. Fixed in OSMO 6.4, which is not released yet. Account keys are blocked by policy. | User delegation SAS for `workflow_data`, rotated every 3 days by a CronJob ([manifests/workflow-data-sas-rotator.yaml](manifests/workflow-data-sas-rotator.yaml)) |
| 5 | GPU containers fail with `No help topic for 'apply-cuda-memory-limits'` | Container toolkit v1.17.8 (pinned by microsoft/physical-ai-toolchain for operator v26.3) is too old for operator v26.7 | Use the chart's toolkit v1.20.1. GPU nodes run Ubuntu 22.04, where it is stable. |
| 6 | GPU submit fails with `There are no resources in platform t4` | OSMO validates against existing nodes, so a pool at 0 nodes cannot receive work | Keep `gpu_node_min_count = 1` while testing, and set it to 0 when idle |

## Known limitations (phase 1)

- **No browser UI login.** This needs an IdP. Add Entra ID through `gateway.oauth2Proxy` plus a JWT provider.
- **Artifacts can only be downloaded from inside the VNet.** Blob has no public endpoint, so `osmo` commands that move data directly between your workstation and storage do not work from outside the VNet.
- **The SAS rotator restarts OSMO pods every 3 days.** OSMO does not reload Secrets on its own. If the CronJob fails for more than about 7 days, artifact uploads fail. Check it with `kubectl get cronjob,jobs -n osmo`.
- **Spot capacity can be evicted.** A running workflow is lost when its node is evicted.
- **The authz component uses `sslmode=require`.** It encrypts the connection but does not verify the PostgreSQL server certificate.

## After OSMO 6.4 is released

1. Move to the unified `osmo` chart. See the upstream `deployments/upgrades/6_3_to_6_4_upgrade.md`.
2. Switch `workflow_data` back to an endpoint-only (Workload Identity) credential, and delete the SAS rotator.
3. Re-check whether the duplicate JWT provider workaround is still needed.
