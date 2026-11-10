# OSMO on Azure: OSMO deployment (Helm)

English | [简体中文](README.zh-CN.md)

This directory deploys NVIDIA OSMO 6.3.1 onto the AKS cluster created by [infra/terraform](../infra/terraform/README.md). It uses the Azure data services from the same Terraform state.

**Status (2026-11-06):** deployed in West US 3. All phase-1 acceptance checks pass (`hello`, `storage`, `gpu`), and OSMO is reachable at a public HTTPS hostname through Traefik.

## Components and versions

| Component | Chart / version | Namespace | Notes |
|---|---|---|---|
| NVIDIA GPU Operator | `nvidia/gpu-operator` v26.7.2 | `gpu-operator` | Driver 595.91.07 on T4 nodes, container toolkit v1.20.1 (the chart default), nvidia as the containerd default runtime |
| KAI Scheduler | `oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler` v0.14.9 | `kai-scheduler` | The KAI line paired with OSMO 6.3.x. GPU runtimeClass injection is disabled. |
| OSMO service | `osmo/service` 1.3.1 (OSMO 6.3.1), release `osmo` | `osmo` | API, router, worker, logger, agent, UI, Envoy gateway, authz |
| OSMO backend operator | `osmo/backend-operator` 1.3.1, release `osmo-operator` | `osmo-operator` | Registers AKS as backend `default`. Workflow pods run in `osmo-workflows`. |
| Traefik (public HTTPS entry, optional) | `traefik/traefik` 42.3.0 (Traefik v3.7.17) | `traefik` | Terminates TLS with your certificate and routes to `osmo-gateway`. Uses the static public IP from infra/terraform. |
| Keycloak (browser login, optional) | Keycloak Operator 26.8.2 (official manifests) | `keycloak` | OIDC provider at `https://<hostname>/auth`, realm `osmo`. Groups `osmo-admins` / `osmo-users` map to OSMO roles through the token `roles` claim. Database `keycloak` on the existing PostgreSQL (dedicated login, TLS). |
| Workflow-data SAS rotator | [manifests/workflow-data-sas-rotator.yaml](manifests/workflow-data-sas-rotator.yaml) | `osmo` | A CronJob that works around an OSMO 6.3.1 bug (see below). Remove it after upgrading to OSMO 6.4. |
| AzureML closed loop (optional) | [workflows/rl-train-validate.yaml](workflows/rl-train-validate.yaml), [workflows/azureml-seed-data.yaml](workflows/azureml-seed-data.yaml) | `osmo-workflows` | Plain OSMO workflows that call AzureML (MLflow, model registry, data assets) with Workload Identity. Nothing is installed in the cluster. See [docs/azureml-loop.md](../docs/azureml-loop.md). |
| Legged sim2sim at scale (optional) | [workflows/legged-seed.yaml](workflows/legged-seed.yaml), [workflows/legged-validate.yaml](workflows/legged-validate.yaml) | `osmo-workflows` | Point-foot biped policies validated in MuJoCo across N parallel CPU tasks, gated and promoted in the AzureML model registry. Robot and policy sources come from `scripts/legged.env` (see `legged.env.example`). See [docs/legged-sim2sim.md](../docs/legged-sim2sim.md). |

## Phase-1 design

- **Authentication.** OSMO-issued tokens only:
  - oauth2-proxy is disabled.
  - authz is enabled, and the gateway validates OSMO JWTs and strips client-supplied identity headers.
  - The `admin` user logs in with an access token stored in the `osmo/osmo-default-admin` Secret.
  - The backend operator uses its own token with the `osmo-backend` role.
  - The web UI needs an identity provider for browser login, so phase 1 is CLI-first. Entra ID through oauth2-proxy comes next.
- **Access.** Two options:
  - `kubectl port-forward`, which goes through the Entra ID–protected AKS API. Always available.
  - A public HTTPS hostname through Traefik (step 5). It uses your certificate and a static IP managed by Terraform, and is open to the internet. Access is protected by OSMO token authentication.
- **Data services.**
  - PostgreSQL uses TLS (`sslmode=require` for authz).
  - Redis uses TLS on port 10000.
  - Credentials come from Terraform sensitive outputs and are written to Kubernetes Secrets when you run the script. Key Vault is private-only; some subscriptions enforce this by policy.
- **Storage.** Blob under `azure://<account>/osmo/...`, reachable only through a private endpoint, with no account keys.
  - `workflow_log` and `workflow_app` use Workload Identity. The control plane runs as ServiceAccount `osmo/osmo`.
  - `workflow_data` (task artifacts) uses a rotating, container-scoped **user delegation SAS**. The SAS is signed with Entra ID, not an account key. See the issues section below for why.
- **Pool `default`.**
  - Platform `default`: CPU-only tasks on the dedicated CPU node pool `npcpu` (nodeSelector plus a toleration for `osmo/workload=cpu`). The system pool runs only the platform components.
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

# Optional: public HTTPS hostname through Traefik
OSMO_HOSTNAME=osmo.example.com TLS_CERT_FILE=/path/fullchain.pem TLS_KEY_FILE=/path/private.key \
  deploy/scripts/05-public-endpoint.sh   # then point a DNS A record at: terraform output ingress_public_ip

# Optional: browser / web UI login with per-user roles (Keycloak), after step 5
OSMO_HOSTNAME=osmo.example.com KEYCLOAK_ADMINS="alice@example.com" KEYCLOAK_USERS="bob@example.com" \
  deploy/scripts/06-keycloak-login.sh    # initial (temporary) passwords: ~/.osmo-keycloak-initial-passwords

# Optional: AzureML closed loop (needs infra/terraform/azureml.tf applied)
deploy/scripts/07-azureml-loop.sh       # seed data asset, then train (T4) -> register -> sim2sim validation (MuJoCo + Gazebo) -> gate
deploy/scripts/08-legged-sim2sim.sh seed import validate   # legged robot: scenario set + policies, then sharded MuJoCo validation -> gate

# After the cluster was stopped (e.g. nightly auto-shutdown)
deploy/scripts/00-resume.sh
```

Keep certificate and key files outside the repository. `.gitignore` blocks `*.pem`, `*.key`, `*.crt`, `*.pfx` and `*.zip` as a safety net.

Every script can be re-run safely. Two values are created once and never overwritten:
- The default admin token (`osmo/osmo-default-admin`)
- The master encryption key (`osmo/mek-config`)

Back up the MEK. Losing it makes the encrypted data in PostgreSQL unreadable.

## Use OSMO

With the public hostname:

```bash
osmo login https://osmo.example.com --method token --token-file <file with the admin access token>
osmo workflow list
```

Read the admin access token with `kubectl get secret osmo-default-admin -n osmo -o jsonpath='{.data.password}' | base64 -d`, and keep it secret.

With port-forward:

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

| `isaaclab` (optional) | [isaaclab-cartpole.yaml](workflows/isaaclab-cartpole.yaml) | Isaac Lab 3.0 headless RL training (official `nvcr.io/nvidia/isaac-lab:3.0.0-kitless` image, Newton `newton_mjwarp` physics, rsl_rl, `Isaac-Cartpole`, 64 envs, 10 iterations) on T4. Checkpoints and TensorBoard logs are uploaded to Blob. | ✅ (2026-11-06) |

| `mujoco` (optional) | [mujoco-sim.yaml](workflows/mujoco-sim.yaml) | MuJoCo 3.17 headless simulation on the CPU platform (`npcpu`): double pendulum plus falling boxes, 10 s simulated. Checks that the boxes come to rest and uploads `trajectory.csv` and `summary.txt`. | ✅ (2026-11-06) |
| `gazebo` (optional) | [gazebo-sim.yaml](workflows/gazebo-sim.yaml) | Gazebo Harmonic (gz-sim 8.11, `osrf/ros:jazzy-simulation`) headless server on `npcpu`: 50,000 iterations of [files/falling_shapes.sdf](workflows/files/falling_shapes.sdf) in about 11 s. Uploads the recorded `state.tlog`. | ✅ (2026-11-06) |
| `07-azureml-loop.sh` (optional) | [rl-train-validate.yaml](workflows/rl-train-validate.yaml) | Data lake → AzureML data asset; Isaac Lab training on T4 with ONNX export; MLflow run and model registration in AzureML; sim2sim validation of the ONNX policy in MuJoCo and Gazebo Harmonic in parallel (100 scenarios each); a gate task logs both runs and tags the model version passed/failed | ✅ (2026-11-09): 100/100 episodes in both simulators; an under-trained policy (5 iterations) is rejected by the gate |
| `08-legged-sim2sim.sh` (optional) | [legged-validate.yaml](workflows/legged-validate.yaml) | Scenario set (1000/1200 scenarios: velocity commands × friction × payload × push × latency) and pretrained point-foot policies registered in AzureML; 10 MuJoCo shards in parallel on the CPU pool; gate on in-distribution fall rate and velocity RMSE with champion/challenger promotion | ✅ (2026-11-10): promotion, gate rejection and re-validation on a new scenario-set version all exercised; see [docs/legged-sim2sim.md](../docs/legged-sim2sim.md) |

Run a subset with `deploy/scripts/04-verify.sh hello storage`, or the simulation samples with `deploy/scripts/04-verify.sh isaaclab mujoco gazebo`.

Simulation samples (each was first validated in a single container on the target node pool):
- Scripts and worlds live in [workflows/files/](workflows/files/) and are injected with the OSMO `files:` field, so the single-container test and the OSMO workflow run the same files.
- MuJoCo has no official container image. The workflow installs the pinned `mujoco` wheel on `python:3.12-slim`.
- Gazebo Classic is EOL, so the sample uses Gazebo Harmonic. The stock example worlds have no `<physics>` block and run in real time; the sample world sets `real_time_factor=0` to run as fast as possible (about 5× real time on D8s_v4).

Isaac Lab 3.0 notes, verified in the container:
- Training uses the unified `scripts/reinforcement_learning/train.py --rl_library rsl_rl`.
- Task IDs have no `-v0` suffix (`Isaac-Cartpole`).
- There is no `--headless` flag: training is headless unless `--visualizer` is given.
- The kitless image runs as the non-root user `isaaclab`.
- The first image pull (5.9 GB) takes about 2.5 minutes. A training run takes about 75 seconds.

## Issues found during deployment and their fixes

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | Gateway port refuses connections. Envoy logs `RequiresAny ... must contain at least 2 item(s)` | `osmo/service` 1.3.1 always renders the catch-all JWT rule as `requires_any`, and Envoy rejects that with only one provider | The OSMO JWT provider is listed twice in [values/osmo-service.yaml](values/osmo-service.yaml). Replace the duplicate with Entra ID in phase 2. |
| 2 | CPU tasks are stuck in `Init` with `no runtime for "nvidia" is configured` | KAI's admission webhook adds `runtimeClassName: nvidia` to every pod that declares `nvidia.com/gpu`. OSMO's default template declares it even when the value is 0. | KAI `admission.gpuPodRuntimeClassName: ""`. On GPU nodes, nvidia is the containerd default runtime instead. |
| 3 | Worker logs `ClusterCrossSlotError` | Azure Managed Redis with `EnterpriseCluster` on a multi-shard SKU rejects multi-key pipelines | Redis `clustering_policy = "NoCluster"` (infra/terraform) |
| 4 | Task artifact upload fails with `KeyError: 'access_key_id'` | OSMO 6.3.1 bug: osmo-ctrl assumes the workflow_data credential has keys. Fixed in OSMO 6.4, which is not released yet. Account keys are blocked by policy. | User delegation SAS for `workflow_data`, rotated every 3 days by a CronJob ([manifests/workflow-data-sas-rotator.yaml](manifests/workflow-data-sas-rotator.yaml)) |
| 5 | GPU containers fail with `No help topic for 'apply-cuda-memory-limits'` | Container toolkit v1.17.8 (pinned by microsoft/physical-ai-toolchain for operator v26.3) is too old for operator v26.7 | Use the chart's toolkit v1.20.1. GPU nodes run Ubuntu 22.04, where it is stable. |
| 6 | GPU submit fails with `There are no resources in platform t4` | OSMO validates against existing nodes, so a pool at 0 nodes cannot receive work | Keep `gpu_node_min_count = 1` while testing, and set it to 0 when idle |
| 7 | CPU submit fails with `Value 1.0 too high for CPU` | The system pool also runs Traefik, KAI, the GPU Operator controllers and policy-injected components such as Defender. OSMO validates against free capacity, not autoscaling. | CPU tasks run on a dedicated node pool `npcpu`, and the system pool runs only the platform components |
| 8 | After the nightly auto-shutdown, osmo-service, worker and agent are missing | Pods are created before the Workload Identity webhook is ready (`failed calling webhook mutation.azure-workload-identity.io`) | `scripts/00-resume.sh` starts AKS and PostgreSQL and restarts the OSMO deployments |
| 9 | Envoy keeps serving the old config, with logs showing `unknown cluster 'oauth2-proxy'` | Envoy loads listeners and clusters from separate files, so a route can briefly reference a cluster that is not loaded yet, and the rejected update is not retried | `02-osmo-service.sh` restarts Envoy after every Helm upgrade |
| 10 | The public IP does not respond on 80/443 | A subscription policy attached a deny-all-inbound NSG to every subnet | infra/terraform manages its own `snet-aks` NSG that allows 80/443 only to the ingress IP |
| 11 | Submit fails with `Value ... too high` although the node is idle, or a new node pool is missing from `osmo resource list` | The backend listener's node cache is stale. For example, it still counts a pod that was deleted outside OSMO. | `kubectl rollout restart deploy -n osmo-operator` |
| 12 | Browser users have the right OSMO role in the database but the UI shows "unable to load" (403) | In ConfigMap mode (`services.configs.enabled`), OSMO authz takes roles only from the token `roles` claim (mapped by `external_roles`); database role assignments are ignored for IdP sessions | Keycloak emits realm roles as the `roles` claim; assign roles with Keycloak groups. (Dex static users cannot emit a `roles` claim, so Dex was replaced.) |
| 13 | Keycloak Operator 26.8 crash-loops (`keycloakoidcclients ... Not Found`) | 26.8 also watches the new OIDC/SAML client CRDs | `06-keycloak-login.sh` installs all four CRDs |
| 14 | Browser session breaks after a few minutes and refreshing the page shows `Jwt is expired` | Keycloak ID tokens lived 5 min, but oauth2-proxy refreshed the session only every 1 h, so the gateway received an expired ID token | Keycloak token lifetime 15 min (SSO idle 8 h, max 12 h, in [manifests/keycloak/realm-osmo.yaml](manifests/keycloak/realm-osmo.yaml)); oauth2-proxy `cookieRefresh: 10m`, `cookieExpire: 12h` |

## Known limitations (phase 1)

- **Azure Policy for Kubernetes runs in audit mode in this subscription.** It reports workflow pods that run as root, have no limits, use images outside ACR, and so on. If a customer environment enforces (denies) these rules, OSMO workflow pods and nvcr.io images will be rejected: mirror images to ACR and adjust the pod templates.

- **Browser login uses Keycloak (step 6).** Manage users and roles in the Keycloak admin console (`https://<hostname>/auth/admin`, realm `osmo`): add a user to group `osmo-admins` or `osmo-users`. In OSMO's ConfigMap mode, browser sessions get roles only from the token `roles` claim, so `osmo user update --add-roles` has no effect on them. The Keycloak admin console is reachable from the internet; protect the admin account with a strong password and OTP. The Entra ID overlay ([values/osmo-service-entra.yaml](values/osmo-service-entra.yaml)) remains as an alternative.
- **Nightly auto-shutdown.** Some subscriptions stop AKS and PostgreSQL every night. Run `scripts/00-resume.sh` before use.

- **Artifacts can only be downloaded from inside the VNet.** Blob has no public endpoint, so `osmo` commands that move data directly between your workstation and storage do not work from outside the VNet.
- **The SAS rotator restarts OSMO pods every 3 days.** OSMO does not reload Secrets on its own. If the CronJob fails for more than about 7 days, artifact uploads fail. Check it with `kubectl get cronjob,jobs -n osmo`.
- **Spot capacity can be evicted.** A running workflow is lost when its node is evicted (it ends in `FAILED_BACKEND_ERROR`; resubmit it). This happened once during the AzureML loop tests.
- **The authz component uses `sslmode=require`.** It encrypts the connection but does not verify the PostgreSQL server certificate.

## After OSMO 6.4 is released

1. Move to the unified `osmo` chart. See the upstream `deployments/upgrades/6_3_to_6_4_upgrade.md`.
2. Switch `workflow_data` back to an endpoint-only (Workload Identity) credential, and delete the SAS rotator.
3. Re-check whether the duplicate JWT provider workaround is still needed.
