# osmo-on-azure

English | [简体中文](README.zh-CN.md)

Deploy [NVIDIA OSMO](https://github.com/NVIDIA/OSMO) on Azure to give embodied-AI and robotics teams a cloud-based scheduling platform for simulation jobs.

## Architecture (PoC phase 1)

![OSMO on Azure architecture](docs/images/azure-architecture.png)

_Edges: green = private (VNet / Private Link) · orange dashed = public entry (AKS API: admin IPs only; HTTPS ingress via Traefik: internet, OSMO/Keycloak authentication) · grey = outbound via NAT · blue dotted = identity / monitoring._

## Documents

| Document | Contents |
|---|---|
| [docs/reference-repos.md](docs/reference-repos.md) (Chinese) | Review of the reference repos (NVIDIA/OSMO, microsoft/physical-ai-toolchain): version choice, PostgreSQL TLS, reusable parts |
| [docs/operations-guide.md](docs/operations-guide.md) (Chinese) | Operations guide: resume the environment, log in, view workflow history and logs, check resources, cost control, troubleshooting |
| [docs/azureml-loop.md](docs/azureml-loop.md) (Chinese) | OSMO + AzureML closed loop: data lake → Isaac Lab training on T4 → MLflow tracking and model registry → sim2sim validation in MuJoCo and Gazebo |
| [docs/hybrid-robot-pipeline.md](docs/hybrid-robot-pipeline.md) (Chinese) | Hybrid robot training and sim2sim pipeline: one OSMO control plane in Azure schedules AKS, another cloud and on-prem GPU; training on-prem, validation in MuJoCo and Gazebo (vendor ROS 2 stack) across pools, results and gating in AzureML |
| [docs/private-storage-security.md](docs/private-storage-security.md) (Chinese) | Private storage design for multi-cloud + on-prem jobs: storage gateway, federated identity, no keys, mapped to security best practices |
| [docs/t4-feasibility.md](docs/t4-feasibility.md) (Chinese) | Feasibility of running Isaac Lab / Isaac Sim / MuJoCo / Gazebo on T4 GPUs |
| [docs/images/](docs/images/) | Azure architecture (with external compute), OSMO + AzureML closed-loop sequence, hybrid training and validation sequence, OSMO deployment architecture, OSMO workflow sequence |
| [infra/terraform/](infra/terraform/README.md) | Azure infrastructure: AKS (system, CPU and T4 Spot GPU pools), private data services, static ingress IP, AzureML workspace and robotics data lake |
| [deploy/](deploy/README.md) | OSMO 6.3.1 deployment (GPU Operator, KAI, OSMO service, backend operator, Traefik, Keycloak), acceptance checks and simulation samples |

## Current status (PoC phase 1)

- **Platform**: NVIDIA OSMO 6.3.1 (open source; `service` and `backend-operator` charts 1.3.1) on AKS in West US 3, provisioned with Terraform.
- **Compute**:
  - System pool for platform components.
  - Dedicated CPU pool `npcpu` for OSMO CPU tasks.
  - NVIDIA T4 Spot pool `npgput4` (driver 595 via the GPU Operator) for GPU tasks.
  - Tasks are scheduled by KAI.
- **Networking**:
  - The AKS API is public and accepts admin IPs only.
  - PostgreSQL, Redis, Blob storage and Key Vault are reached over private networking only.
  - OSMO is published at a public HTTPS hostname through Traefik, using your own certificate and a static IP.
- **Authentication**:
  - Web UI: Keycloak (official Operator). Users sign in with username and password, and OSMO roles (`osmo-admin` / `osmo-user`) come from Keycloak groups.
  - CLI and automation: OSMO access tokens.
- **Validated**:
  - Main path: login → submit → queue → schedule → status → logs → artifacts.
  - Simulation samples:
    - Isaac Lab 3.0 headless training on T4
    - MuJoCo on the CPU pool
    - Gazebo Harmonic on the CPU pool
- **AzureML closed loop** ([docs/azureml-loop.md](docs/azureml-loop.md)):
  - OSMO runs the work; AzureML is the system of record for experiments (MLflow), models and data assets.
  - One OSMO workflow trains a policy with Isaac Lab on T4, registers it in AzureML, validates it in MuJoCo and Gazebo (sim2sim), and a success-rate gate tags the model version as passed or failed.
  - Data comes from a private ADLS Gen2 data lake registered as an AzureML data asset. All access uses Workload Identity.
- **Hybrid compute: other clouds and on-prem, results in Azure** ([docs/hybrid-robot-pipeline.md](docs/hybrid-robot-pipeline.md), [docs/private-storage-security.md](docs/private-storage-security.md)):
  - External Kubernetes clusters (simulated: k3s in another region and network; k3s on an H100 server) join OSMO as pools. They only make outbound HTTPS connections: no inbound ports, no VPN or peering.
  - Storage stays private-only. External jobs reach it through an SNI-passthrough storage gateway on the public entry (TLS end to end, egress-IP allow-list) and authenticate with the OSMO managed identity through workload identity federation, with no keys.
  - Pipeline: Isaac Lab training on the on-prem H100 → AzureML model registry → sim2sim shards spread over three pools → results in the Azure data lake → gate and promotion in AzureML.
- **Legged robot sim2sim at scale** ([docs/hybrid-robot-pipeline.md](docs/hybrid-robot-pipeline.md)):
  - Replaces manual, joystick-driven sim2sim checks: two pretrained point-foot biped policies run through 1000–1200 MuJoCo scenarios (velocity commands × friction × payload × push × latency) in 10 parallel OSMO tasks.
  - A second simulator runs the vendor's own ROS 2 deployment stack (Gazebo Classic + ros2_control + C++ RL controller) on a scenario subset, from an image built in the cluster and stored in a private ACR; a model must pass in both simulators.
  - A gate on fall rate and velocity tracking decides which version becomes `stage=production` (champion/challenger), and a new scenario-set version re-validates every registered model.
- **Known limitations**: see [deploy/README.md](deploy/README.md#known-limitations-phase-1). For example, the workflow-data SAS workaround stays in place until OSMO 6.4, and the subscription shuts the environment down every night.
