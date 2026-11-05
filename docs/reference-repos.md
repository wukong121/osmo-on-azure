# 参考仓库研读结论

> 研读时间：2026-11-05
> - NVIDIA/OSMO：`main` @ `c0f208d`（2026-10-28）。最新**正式发布**版本是 `6.3.1`（2026-06-22）。`6.4.0` 只打了 git tag（2026-10-26），还没有发布
> - microsoft/physical-ai-toolchain：`main` @ `c02fba7`（2026-11-04）

## 1. 一句话结论

- **以 NVIDIA/OSMO 官方路径为骨架**：Terraform 用 `deployments/terraform/azure/example`。OSMO 用**已正式发布的 6.3.1**，即 NGC 上的 `service` 和 `backend-operator` 两个 chart，版本 1.3.1（详见 2.0 节）。
- **从 physical-ai-toolchain 借鉴私网和身份相关的设计**：Private Endpoint、Private DNS、Key Vault、ACR、Workload Identity，以及 AKS 上 GPU Operator 的调优经验。
- **不要直接整体复用 physical-ai-toolchain**。它强依赖 AzureML，认证也是 dev 模式。不过它跟我们一样用 OSMO 6.3.1，它的 Helm values 和部署脚本可以作为重要参考。

## 2. NVIDIA/OSMO

### 2.0 版本选择：用 6.3.1（2026-11-05 核实）

| 检查项 | 结果 |
|---|---|
| GitHub Releases | 最新的 Latest 是 **6.3.1**（2026-06-22）。6.4.0 只有 tag，没有 Release |
| NGC Helm 仓库 `https://helm.ngc.nvidia.com/nvidia/osmo` | 只有 `service` / `backend-operator` / `quick-start` 等旧 chart，最新 **1.3.1（appVersion 6.3.1）**。**还没有统一的 `osmo` chart**（index 生成时间 2026-06-22） |
| nvcr.io `nvidia/osmo/service` 镜像 tag | 最新是 `6.3.1`，**没有 `6.4.0`** |
| tag 6.4.0 中的 `charts/osmo/Chart.yaml` | `version: 0.1.0`，`appVersion: "6.3.1"`，镜像默认用 `latest` |

结论：
- PoC 锁定 **OSMO 6.3.1**：chart 用 `service` 1.3.1 和 `backend-operator` 1.3.1，镜像用 `6.3.1`。
- KAI 用 6.3 对应的 0.14.x。OSMO 6.3.1 脚本默认是 0.14.0，physical-ai-toolchain 锁的是 v0.14.9。
- 6.3.1 的认证架构：Envoy gateway 加 oauth2-proxy（通用 OIDC，填 `oidcIssuerUrl` 即可），后端可以接 Keycloak，也可以接 **Entra ID**。所以架构图里的 Keycloak 仍然是一个有效选项。
- 等 6.4 正式发布后，再按 `6_3_to_6_4_upgrade.md` 迁移到统一 chart。下面 2.1 节是 `main` 分支（6.4）的变化，留作参考。

### 2.1 main 分支（6.4）的架构变化（参考）

- OSMO **6.4** 用统一的 `osmo` chart 替换了旧的 `service` 和 `backend-operator` 两个 chart，见 `deployments/upgrades/6_3_to_6_4_upgrade.md`。
- 统一 chart 自带几个可选依赖：**Dex**（认证）、Valkey、CloudNativePG（PostgreSQL）、RustFS（对象存储）。
- **认证从 Keycloak 换成了 Dex 或外部 OIDC**：
  - 内置 Dex 把数据放在内存里，只适合开发和评估。生产环境要求设置 `authentication.provider: externalOidc`。
  - 架构图里的 Keycloak 是旧版本的画法。现在文档里 Keycloak 只出现在 appendix 中，作为可选的 IdP。
- 有 4 个 chart profile，都在 `deployments/charts/osmo/profiles/`：
  - `self-contained`：所有依赖都跑在集群内。
  - `single-plane`：控制面和计算面在同一个集群，**PostgreSQL、Redis/Valkey、对象存储用外部的托管服务**。**本 PoC 选这个。**
  - `split-plane-control` / `split-plane-compute`：控制面和计算面分开部署。后续做多集群或混合调度时用。
- 前置组件：
  - **KAI Scheduler 0.15.3**，必需。
  - GPU Operator v25.10.1，安装脚本的默认版本。
- 系统要求：
  - OSMO Service 需要 8 核、32 GB 内存，系统节点池按 D8s 级别规划。
  - PostgreSQL 15 以上。
  - Redis 或 Valkey 7 以上。

### 2.2 Azure Terraform 示例（`deployments/terraform/azure/example`）

| 资源 | 现状 | 是否满足“数据组件私网”的要求 |
|---|---|---|
| VNet | 有 private 子网和 database 子网，private 子网走 NAT Gateway 出网 | ✅ |
| AKS | `aks_private_cluster_enabled` 默认 true，可以改成公网 API；启用了 Entra ID + Azure RBAC、Container Insights | ✅（PoC 改为公网 API） |
| GPU 节点池 | 可选，带 taint `nvidia.com/gpu=present:NoSchedule`，`gpu_driver` 默认 `None`（驱动交给 GPU Operator 安装），支持 Spot | ✅ 直接用，改 SKU 即可 |
| PostgreSQL Flexible | VNet 注入（delegated subnet）+ Private DNS，关闭了公网 | ✅ 但示例里设了 **`require_secure_transport=off`**。已确认**可以保持 Azure 默认的 `on`**，见 2.4 节 |
| Azure Managed Redis | 使用 access key，TLS，EnterpriseCluster 模式 | ❌ **没有 Private Endpoint，公网可以访问**，需要补 PE 和 `privatelink.redis.azure.net` |
| Blob（WI 方式） | 关闭了 Shared Key，用 UAMI 加联邦凭据 | ⚠️ 没有网络限制，需要补 PE 和 `privatelink.blob.core.windows.net`，并关闭公网 |
| Key Vault / ACR | 没有 | ❌ 需要新增 |
| NSG | AKS 子网放行了任意来源的 443 | ⚠️ 需要按实际访问方式收紧 |

注意事项：
- 官方示例说 Redis 必须用 `EnterpriseCluster`，不能用 `OSSCluster`，否则会出现 `MOVED` 错误。**实测更正（2026-11-05）**：在多分片的 SKU 上，`EnterpriseCluster` 仍然会因为跨 slot 的多 key pipeline 报 `ClusterCrossSlotError`。25 GB 及以下的 SKU 应该用 **`NoCluster`**。这个设置会让 database 重建。
- 必须开启 `access_keys_authentication_enabled = true`，否则 Terraform 拿不到 key。

### 2.3 部署脚本与验证用例

- 涉及的脚本：
  - `deployments/scripts/deploy-osmo.sh` 和 `lib/deploy.py`
  - `deploy-osmo-single-plane.sh`：Azure 上用 Workload Identity 的单平面示例，也是官方 CI 用的路径
  - `install-kai-scheduler.sh`、`install-gpu-operator.sh`
- `scripts/single-plane-azure.yaml` 是 Azure 的 values 覆盖示例，内容包括：
  - Workload Identity 的 pod label
  - 对象存储使用 `sdkDefault` 认证
  - 管理员 token 放在 Secret 里
  - 把 pod template 加到 pool 上
- 验证 workflow 在 `deployments/workflows/` 下：`verify-hello.yaml`（CPU）、`verify-gpu.yaml`（`nvidia-smi`）、`verify-object-storage.yaml`。**可以直接拿来做第一阶段的验收用例。**
- `--find-gpu-region SKU COUNT` 可以查 GPU 配额在哪些 region 可用。

### 2.4 PostgreSQL TLS：可以开启（2026-11-05 核实，基于 6.3.1 源码）

| 组件 | 连接方式 | 开启 TLS 强制后的表现 |
|---|---|---|
| Python 服务（`src/utils/connectors/postgres.py`） | psycopg2 连接池，没有显式指定 `sslmode`，所以用 libpq 默认值 `prefer` | 服务端支持 TLS 时会自动走 TLS ✅ |
| Go 组件（`src/utils/postgres/postgres_client.go`） | `--postgres-ssl-mode` / `OSMO_POSTGRES_SSL_MODE`，默认 `prefer`，支持 `require` / `verify-full` | ✅ |
| 数据库迁移（`charts/service/migrations/run_migrations.sh`） | pgroll URL 写死了 `sslmode=require` | 本身就要求 TLS ✅ |
| gateway authz | `gateway.authz.postgres.sslMode`，默认 `prefer` | ✅ |

旁证：physical-ai-toolchain 部署的也是 OSMO 6.3.1，它的 PostgreSQL **没有修改 `require_secure_transport`**（保持 Azure 默认的 `on`），用 Private Endpoint 接入。

结论：
- **保持 `require_secure_transport=on`**，删掉官方示例里的 `ssl_off` 配置。
- 局限：Python 服务用的是 `prefer`，只加密传输，不校验服务端证书。在私网内这个风险可以接受。Go 组件可以设成 `require`。

## 3. microsoft/physical-ai-toolchain

### 3.1 定位

这是一个覆盖机器人开发全流程的 monorepo，包括训练、评估、SDG、部署和数据管线。OSMO 和 **AzureML** 并列为两条作业路径。Azure 基础设施在 `infrastructure/terraform`（Terraform）和 `infrastructure/setup`（脚本加 Helm values）里。

### 3.2 OSMO 部署方式

- 用的是 **OSMO 6.3.1**（也就是当前正式发布的版本）：`service` chart 1.3.1 和 `backend-operator`。KAI 版本是 v0.14.9，GPU Operator 是 v26.3.2。版本都在 `infrastructure/setup/defaults.conf` 里定义。
- 部署顺序：
  1. `01-deploy-robotics-charts.sh`：安装 GPU Operator 和 KAI。
  2. `02-deploy-azureml-extension.sh`：安装 AzureML extension。
  3. `03-deploy-osmo.sh`：安装 OSMO。
- **认证是 dev 模式**：
  - 关闭了 oauth2-proxy 和 authz，Envoy 默认给所有请求 admin 身份。
  - CLI 用 `osmo login --method dev`。
  - **没有 Keycloak，也没有对接 OIDC。**
- **入口依赖 AzureML extension 自带的 nginx**（`azureml-nginx`）。再加一个固定私网 IP 的内部 LoadBalancer，用户通过 VPN 访问。

### 3.3 值得借鉴的部分

| 内容 | 位置 | 用途 |
|---|---|---|
| Private Endpoint 子网和全套 Private DNS Zone（KV、blob、file、ACR、redis、postgres、monitor 等） | `infrastructure/terraform/modules/platform` | 补齐数据组件私网 |
| 公网访问总开关 `should_enable_public_network_access`，加上按资源单独覆盖的 `public_network_access_overrides` | 同上 | 实现“AKS 公网、数据组件私网”的组合 |
| Key Vault（RBAC 模式）存放 PG 和 Redis 密码，用 SecretProviderClass（CSI + WI）同步到集群 | `platform` 模块和 `infrastructure/setup/manifests/aks-secret-provider-class*.yaml` | 密钥管理 |
| ACR（Premium，关闭 admin 账号），以及 `import-osmo-to-acr.sh` 镜像同步脚本 | `platform` 模块和 setup 脚本 | 私网拉取镜像，可选 |
| OSMO 相关 SA 的 UAMI 联邦凭据 | `modules/sil/osmo-federated-credentials.tf` | Workload Identity。6.3.1 下 SA 名称可以直接沿用 |
| AKS 上 GPU Operator 的调优经验：跳过 AKS 已装驱动的节点，toolkit 锁定 `v1.17.8` 以兼容 AKS containerd（**注意**：这个版本只适用于 operator v26.3；在 v26.7 上 GPU 容器会启动失败，要改用 chart 自带的 v1.20.1，并配合 Ubuntu 22.04 的 GPU 节点）；K8s 1.35 下 GPU 池用 `Ubuntu2204` | `infrastructure/setup/values/nvidia-gpu-operator.yaml`、`docs/reference/gpu-configuration.md` | 规避坑点 |
| 本地冒烟 workflow（CPU 任务、GPU 任务、输入输出数据往返） | `infrastructure/local/workflows/osmo-smoke.yaml` | 参考验收用例 |

### 3.4 不适合直接复用的部分

- `platform` 模块**一定会创建 AzureML workspace**，另外 Grafana、AMPLS、Defender 默认都开着，费用和复杂度都偏高。
- Key Vault 和存储账号设置了 `prevent_destroy`，PoC 反复部署和销毁时会被挡住。
- 默认 GPU 池是 Spot 的 `NV36ads_A10_v5`，platform 定义写死了 A100。示例里的 Isaac Lab 作业要 30 CPU、400Gi 内存，T4 机型跑不了。
- 没有 Gazebo 和 MuJoCo 的示例。
- 用 Terraform 写 KV secret、执行 `az keyvault secret show` 都属于数据面操作。数据组件关掉公网以后，执行这些操作的机器必须在 VNet 内（跳板机或 VPN），或者临时给防火墙开例外。

## 4. 对本 PoC 的落地建议

1. **Terraform**：以 OSMO 官方 Azure example 为基础，做以下改动：
   - AKS 改为公网 API，加 `authorized_ip_ranges` 限制来源 IP。
   - 系统池用 D8s 级别。
   - 新增 T4 GPU 节点池，用 Regular 优先级，不用 Spot。
   - 参照 physical-ai-toolchain 新增 PE 子网，给 Redis、Blob、Key Vault、ACR（可选）加 Private Endpoint 和对应的 Private DNS Zone，并关闭这些资源的公网访问。
   - 去掉 Redis 和存储账号的公网暴露。
2. **OSMO**：
   - 用 6.3.1，chart 用 `service` 和 `backend-operator` 1.3.1。外部依赖接 PostgreSQL Flexible（开启 TLS）、Azure Managed Redis 和 Blob（Workload Identity）。
   - 部署脚本和 values 主要参考 physical-ai-toolchain 的 `03-deploy-osmo.sh` 和 `values/osmo-*.yaml`，把其中 AzureML 相关的部分去掉。
   - KAI 用 0.14.x。GPU Operator 负责安装 T4 驱动，驱动版本见 `docs/t4-feasibility.md`。
3. **认证**：第一阶段可以先用 dev 模式或管理员 token，把主链路跑通。接着通过 oauth2-proxy 接 Entra ID（OIDC），这一步基本就是验证时序图里的“1. 认证与授权”。
4. **访问**：第一阶段 OSMO UI/API 先用 port-forward 访问，或者只开内部 LB。正式接入方式在网络方案里再定。
5. **验收**：以 OSMO 自带的 `verify-hello`、`verify-gpu`、`verify-object-storage` 为基础，对照时序图的 8 个阶段逐项验证，见 `docs/background.md` 4.4 节。

## 5. 部署实测补充（2026-11-05）

实际部署时发现的 6 个问题和对应修复，见 [deploy/README.zh-CN.md](../deploy/README.zh-CN.md#部署中发现的问题与修复)。和本文结论直接相关的有以下几条：
- OSMO 6.3.1 存在两个 bug：
  - `requires_any` 只有一个 JWT provider 时，Envoy 网关无法启动。
  - workflow_data 只配置 endpoint、不带密钥时，osmo-ctrl 在 `access_key_id` 上报 KeyError。6.4 已修复。
- physical-ai-toolchain 的 KAI values 里没有 `admission.gpuPodRuntimeClassName: ""`，CPU 任务会被注入 nvidia runtimeClass。OSMO 官方的 kai-values 里有这一项。
- MCAPS 类订阅的策略会强制关闭存储账号的 Shared Key，以及 Key Vault 和存储的公网访问，还会自动给公网 IP 加 `ip_tags`。
