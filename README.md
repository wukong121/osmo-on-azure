# osmo-on-azure

English | [简体中文](README.zh-CN.md)

Deploy [NVIDIA OSMO](https://github.com/NVIDIA/OSMO) on Azure to give embodied-AI and robotics teams a cloud-based scheduling platform for simulation jobs.

## Architecture (PoC phase 1)

![OSMO on Azure architecture](docs/images/azure-architecture.png)

_Edges: green = private (VNet / Private Link) · orange dashed = public entry (AKS API: admin IPs only; HTTPS ingress via Traefik: internet, OSMO/Keycloak authentication) · grey = outbound via NAT · blue dotted = identity / monitoring._

## Documents

| Document | Contents |
|---|---|
| [docs/background.md](docs/background.md) (Chinese) | Project background, technology choices, PoC success criteria, open items |
| [docs/reference-repos.md](docs/reference-repos.md) (Chinese) | Review of the reference repos (NVIDIA/OSMO, microsoft/physical-ai-toolchain): version choice, PostgreSQL TLS, reusable parts |
| [docs/operations-guide.md](docs/operations-guide.md) (Chinese) | Operations guide: resume the environment, log in, view workflow history and logs, check resources, cost control, troubleshooting |
| [docs/t4-feasibility.md](docs/t4-feasibility.md) (Chinese) | Feasibility of running Isaac Lab / Isaac Sim / MuJoCo / Gazebo on T4 GPUs |
| [docs/images/](docs/images/) | Azure architecture, OSMO deployment architecture, OSMO workflow sequence |
| [infra/terraform/](infra/terraform/README.md) | Azure infrastructure: AKS (system, CPU and T4 Spot GPU pools), private data services, static ingress IP |
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
- **Known limitations**: see [deploy/README.md](deploy/README.md#known-limitations-phase-1). For example, the workflow-data SAS workaround stays in place until OSMO 6.4, and the subscription shuts the environment down every night.
