# OSMO on Azure：OSMO 部署（Helm）

[English](README.md) | 简体中文

这里的脚本把 NVIDIA OSMO 6.3.1 部署到 [infra/terraform](../infra/terraform/README.zh-CN.md) 创建的 AKS 集群上，并接入同一份 Terraform state 里的 Azure 数据服务。

**状态（2026-11-06）**：已在 West US 3 部署完成。第一阶段的三项验收（`hello`、`storage`、`gpu`）全部通过，并已通过 Traefik 开放公网 HTTPS 域名访问。

## 组件与版本

| 组件 | Chart / 版本 | 命名空间 | 说明 |
|---|---|---|---|
| NVIDIA GPU Operator | `nvidia/gpu-operator` v26.7.2 | `gpu-operator` | T4 节点驱动 595.91.07；container toolkit v1.20.1（chart 默认版本）；nvidia 设为 containerd 默认运行时 |
| KAI Scheduler | `oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler` v0.14.9 | `kai-scheduler` | 与 OSMO 6.3.x 配套；关闭了 GPU runtimeClass 自动注入 |
| OSMO service | `osmo/service` 1.3.1（OSMO 6.3.1），release `osmo` | `osmo` | API、Router、Worker、Logger、Agent、UI、Envoy 网关、authz |
| OSMO backend operator | `osmo/backend-operator` 1.3.1，release `osmo-operator` | `osmo-operator` | 把 AKS 注册为 backend `default`；工作流 Pod 运行在 `osmo-workflows` |
| Traefik（公网 HTTPS 入口，可选） | `traefik/traefik` 42.3.0（Traefik v3.7.17） | `traefik` | 用你提供的证书终止 TLS，转发到 `osmo-gateway`；使用 infra/terraform 管理的固定公网 IP |
| workflow-data SAS 轮换器 | [manifests/workflow-data-sas-rotator.yaml](manifests/workflow-data-sas-rotator.yaml) | `osmo` | 绕过 OSMO 6.3.1 bug 的 CronJob（原因见下文），升级到 OSMO 6.4 后删除 |

## 第一阶段设计

- **认证**：只使用 OSMO 签发的 token。
  - 关闭 oauth2-proxy。
  - 开启 authz：网关校验 OSMO JWT，并剥离客户端自带的身份头。
  - `admin` 用户用 `osmo/osmo-default-admin` Secret 里的 access token 登录。
  - backend operator 使用单独的 token，角色为 `osmo-backend`。
  - Web UI 需要 IdP 才能在浏览器里登录，所以第一阶段以 CLI 为主，下一步通过 oauth2-proxy 接入 Entra ID。
- **访问**：有两种方式。
  - `kubectl port-forward`：经过受 Entra ID 保护的 AKS API，任何时候都能用。
  - 通过 Traefik 访问公网 HTTPS 域名（第 5 步）：使用你提供的证书和 Terraform 管理的固定 IP，入口对公网开放，安全上依靠 OSMO 的 token 认证。
- **数据服务**：
  - PostgreSQL 走 TLS（authz 使用 `sslmode=require`）。
  - Redis 走 TLS，端口 10000。
  - 凭据在运行脚本时从 Terraform 的敏感输出读取，写入 Kubernetes Secret。Key Vault 仅私网访问，部分订阅会用策略强制要求这一点。
- **存储**：Blob 路径为 `azure://<account>/osmo/...`，只能经私有终结点访问，不使用账号密钥。
  - `workflow_log` 和 `workflow_app` 使用 Workload Identity，控制面使用 ServiceAccount `osmo/osmo`。
  - `workflow_data`（任务产物）使用定期轮换的、容器级的**用户委托 SAS**。这个 SAS 由 Entra ID 签发，不依赖账号密钥，原因见下文。
- **资源池 `default`**：
  - 平台 `default`：仅 CPU 任务，运行在专用的 CPU 节点池 `npcpu` 上（通过 nodeSelector 指定节点池，并容忍 `osmo/workload=cpu` taint）。系统节点池只运行平台组件。
  - 平台 `t4`：每个任务 1 张 T4，运行在 Spot 节点池 `npgput4`。默认 4 CPU、32 GiB 内存、50 GiB 存储，并容忍 `nvidia.com/gpu` 和 Spot 两个 taint。

## 前置条件

- 已 apply `infra/terraform`，并且能读取它的 state。脚本会访问 AKS API，所以本机出口 IP 必须在 `admin_ip_cidrs` 里。
- 测试期间至少保留 1 个 GPU 节点（`gpu_node_min_count = 1`）。OSMO 不接受提交到没有节点的平台，详见下文“部署中发现的问题与修复”。
- 工具：`az`（已登录）、`terraform`、`kubectl`、`kubelogin`、`helm`（v3 或 v4）、`jq`、`python3`、`openssl`、`envsubst`。
- [OSMO CLI 6.3.1](https://github.com/NVIDIA/OSMO/releases/tag/6.3.1)，第 3、4 步会用到：

  ```bash
  curl -fsSLO https://github.com/NVIDIA/OSMO/releases/download/6.3.1/osmo-client-installer-6.3.1-linux-x86_64.sh
  bash osmo-client-installer-6.3.1-linux-x86_64.sh   # 安装到 /usr/local/osmo（会用 sudo）
  ```

## 部署

```bash
deploy/scripts/01-cluster-addons.sh   # GPU Operator + KAI Scheduler
deploy/scripts/02-osmo-service.sh     # Secret、MEK、SAS 轮换器、OSMO service chart
deploy/scripts/03-osmo-backend.sh     # backend-operator token + chart，注册 backend "default"
deploy/scripts/04-verify.sh           # 第一阶段验收工作流

# 可选：通过 Traefik 开放公网 HTTPS 域名
OSMO_HOSTNAME=osmo.example.com TLS_CERT_FILE=/path/fullchain.pem TLS_KEY_FILE=/path/private.key \
  deploy/scripts/05-public-endpoint.sh   # 然后把 DNS A 记录指向：terraform output ingress_public_ip

# 集群被停止后恢复（例如每晚的自动停机）
deploy/scripts/00-resume.sh
```

证书和私钥文件请放在仓库之外。`.gitignore` 已经屏蔽了 `*.pem`、`*.key`、`*.crt`、`*.pfx`、`*.zip`，作为兜底防护。

每个脚本都可以安全地重复执行。有两样东西只在第一次运行时生成，之后不会被覆盖：
- 默认管理员 token（`osmo/osmo-default-admin`）
- 主加密密钥 MEK（`osmo/mek-config`）

请务必备份 MEK。MEK 一旦丢失，PostgreSQL 里加密的数据就无法再读取。

## 使用 OSMO

通过公网域名：

```bash
osmo login https://osmo.example.com --method token --token-file <存放管理员 access token 的文件>
osmo workflow list
```

管理员 access token 可以用 `kubectl get secret osmo-default-admin -n osmo -o jsonpath='{.data.password}' | base64 -d` 读取，请妥善保管。

通过 port-forward：

```bash
kubectl port-forward -n osmo svc/osmo-gateway 9000:80 &
osmo login http://127.0.0.1:9000 --method token \
  --token-file <(kubectl get secret osmo-default-admin -n osmo -o jsonpath='{.data.password}' | base64 -d)

osmo pool list
osmo workflow submit deploy/workflows/hello.yaml --pool default
osmo workflow logs <workflow-id>
```

## 第一阶段验收

`04-verify.sh` 覆盖了 [工作流时序图](../docs/images/osmo_workflow_sequence.svg) 里的各个阶段：

| 检查项 | 工作流 | 覆盖的阶段 | 结果（2026-11-05） |
|---|---|---|---|
| `hello` | [hello.yaml](workflows/hello.yaml) | token 登录、提交与排队、backend operator 创建 Pod、状态、日志、完成 | ✅ |
| `storage` | [storage-roundtrip.yaml](workflows/storage-roundtrip.yaml) | 产物经私有终结点上传到 Blob，并被下游任务下载 | ✅ |
| `gpu` | [gpu-t4.yaml](workflows/gpu-t4.yaml) | KAI 调度到 Spot T4 池、GPU 驱动、容器内 `nvidia-smi`（`Tesla T4, 595.91.07, 16384 MiB`） | ✅ |

另外直接对网关做了检查：
- 不带 token 的请求返回 401。
- 伪造 `x-osmo-user` / `x-osmo-roles` 身份头的请求同样返回 401。
- 管理员 access token 能换到 OSMO JWT。

| `isaaclab`（可选） | [isaaclab-cartpole.yaml](workflows/isaaclab-cartpole.yaml) | 在 T4 上运行 Isaac Lab 3.0 headless 强化学习训练：官方镜像 `nvcr.io/nvidia/isaac-lab:3.0.0-kitless`，Newton 物理后端（`newton_mjwarp`），rsl_rl 算法，任务 `Isaac-Cartpole`，64 个并行环境，10 次迭代。checkpoint 和 TensorBoard 日志会上传到 Blob | ✅（2026-11-06） |

| `mujoco`（可选） | [mujoco-sim.yaml](workflows/mujoco-sim.yaml) | 在 CPU 平台（`npcpu`）上运行 MuJoCo 3.17 headless 仿真：双摆加若干下落的盒子，仿真时长 10 秒。校验盒子最终静止在地面上，并上传 `trajectory.csv` 和 `summary.txt` | ✅（2026-11-06） |
| `gazebo`（可选） | [gazebo-sim.yaml](workflows/gazebo-sim.yaml) | 在 `npcpu` 上以 headless server 模式运行 Gazebo Harmonic（gz-sim 8.11，镜像 `osrf/ros:jazzy-simulation`），执行 [files/falling_shapes.sdf](workflows/files/falling_shapes.sdf) 50,000 次迭代，耗时约 11 秒，并上传录制的 `state.tlog` | ✅（2026-11-06） |

只跑其中几项：`deploy/scripts/04-verify.sh hello storage`；只跑仿真示例：`deploy/scripts/04-verify.sh isaaclab mujoco gazebo`。

关于仿真示例（每个示例都先在目标节点池上用单个容器验证过）：
- 脚本和世界文件放在 [workflows/files/](workflows/files/) 中，通过 OSMO 的 `files:` 字段注入容器，所以单容器验证和 OSMO 作业运行的是同一份文件。
- MuJoCo 没有官方容器镜像，作业在 `python:3.12-slim` 基础上安装固定版本的 `mujoco` wheel。
- Gazebo Classic 已经停止维护，所以示例使用 Gazebo Harmonic。官方示例世界没有 `<physics>` 配置块，会按实时速度运行；示例世界设置了 `real_time_factor=0`，让仿真尽可能快地运行（在 D8s_v4 上约为实时速度的 5 倍）。

以下 Isaac Lab 3.0 的要点已在容器内实际验证：
- 训练入口统一为 `scripts/reinforcement_learning/train.py --rl_library rsl_rl`。
- 任务 ID 不再带 `-v0` 后缀（例如 `Isaac-Cartpole`）。
- 没有 `--headless` 参数：只要不指定 `--visualizer`，训练就以 headless 方式运行。
- kitless 镜像以非 root 用户 `isaaclab` 运行。
- 首次拉取镜像（5.9 GB）约 2.5 分钟，单次训练约 75 秒。

## 部署中发现的问题与修复

| # | 现象 | 原因 | 修复 |
|---|---|---|---|
| 1 | 网关端口拒绝连接，Envoy 日志报 `RequiresAny ... must contain at least 2 item(s)` | `osmo/service` 1.3.1 总是把兜底的 JWT 规则渲染成 `requires_any`，而只有一个 provider 时 Envoy 会拒绝这份配置 | 在 [values/osmo-service.yaml](values/osmo-service.yaml) 里把 OSMO 的 JWT provider 配置两次；第二阶段换成 Entra ID |
| 2 | CPU 任务卡在 `Init`，报错 `no runtime for "nvidia" is configured` | KAI 的 admission webhook 会给所有声明了 `nvidia.com/gpu` 的 Pod 加上 `runtimeClassName: nvidia`，而 OSMO 默认模板即使值为 0 也会声明这个资源 | KAI 设置 `admission.gpuPodRuntimeClassName: ""`；GPU 节点改为把 nvidia 设成 containerd 默认运行时 |
| 3 | Worker 报 `ClusterCrossSlotError` | Azure Managed Redis 在多分片 SKU 上使用 `EnterpriseCluster` 时，会拒绝跨 slot 的多 key pipeline | Redis 改为 `clustering_policy = "NoCluster"`（infra/terraform） |
| 4 | 任务产物上传报 `KeyError: 'access_key_id'` | OSMO 6.3.1 的 bug：osmo-ctrl 默认 workflow_data 凭据里一定有密钥。6.4 已修复但尚未发布；账号密钥又被订阅策略禁用 | `workflow_data` 改用用户委托 SAS，由 CronJob 每 3 天轮换一次（[manifests/workflow-data-sas-rotator.yaml](manifests/workflow-data-sas-rotator.yaml)） |
| 5 | GPU 容器启动失败，报 `No help topic for 'apply-cuda-memory-limits'` | container toolkit v1.17.8 是 microsoft/physical-ai-toolchain 为 operator v26.3 锁定的版本，对 operator v26.7 来说太旧 | 改用 chart 自带的 toolkit v1.20.1；GPU 节点运行 Ubuntu 22.04，在这个系统上运行稳定 |
| 6 | 提交 GPU 任务报 `There are no resources in platform t4` | OSMO 按现有节点校验资源，节点池缩到 0 时无法接收任务 | 测试期间设置 `gpu_node_min_count = 1`，闲置时改回 0 |
| 7 | 提交 CPU 任务报 `Value 1.0 too high for CPU` | 系统池上还运行着 Traefik、KAI、GPU Operator 控制器，以及订阅策略注入的 Defender 等组件；OSMO 按节点当前空闲资源校验，不会触发自动扩容 | CPU 任务改到专用节点池 `npcpu` 上运行，系统节点池只运行平台组件 |
| 8 | 每晚自动停机后，osmo-service、worker、agent 等组件缺失 | 集群启动时 Workload Identity 的 webhook 还没就绪，Pod 创建失败（`failed calling webhook mutation.azure-workload-identity.io`） | 运行 `scripts/00-resume.sh`：启动 AKS 和 PostgreSQL，并重启 OSMO 的各个 Deployment |
| 9 | Envoy 一直沿用旧配置，日志报 `unknown cluster 'oauth2-proxy'` | Envoy 从两个文件分别加载监听器和集群配置，路由可能引用了一个还没加载的集群，被拒绝的更新不会自动重试 | `02-osmo-service.sh` 在每次 Helm 升级后重启 Envoy |
| 10 | 公网 IP 的 80/443 端口不通 | 订阅策略给每个子网都自动挂上了默认拒绝所有入站流量的 NSG | infra/terraform 为 `snet-aks` 创建自管的 NSG，只允许访问入口 IP 的 80/443 |
| 11 | 节点明明空闲，提交时却报 `Value ... too high`；或者新加的节点池没有出现在 `osmo resource list` 里 | backend listener 的节点缓存过期了，例如还在统计一个已经在 OSMO 之外被删掉的 Pod | `kubectl rollout restart deploy -n osmo-operator` |

## 已知限制（第一阶段）

- **本订阅的 Azure Policy for Kubernetes 处于 audit（审计）模式**：它会对工作流 Pod 以 root 运行、未设置 limits、镜像不在 ACR 中等情况发出告警，但不会拦截。如果客户环境把这些规则设为强制（deny），OSMO 的工作流 Pod 和 nvcr.io 镜像都会被拒绝，届时需要把镜像同步到 ACR，并相应调整 pod 模板。

- **暂无浏览器登录**：Entra ID 配置层（[values/osmo-service-entra.yaml](values/osmo-service-entra.yaml)）已经验证到 Entra 登录页，但在测试租户里会停在“需要管理员批准”，原因是来宾账号不能自行同意。请改用一个你能授予管理员同意的租户来注册应用。启用方法：先创建 Secret `osmo/oauth2-proxy-secrets`，再带上 `ENTRA_CLIENT_ID` 和 `ENTRA_TENANT_ID` 两个环境变量运行 `02-osmo-service.sh`。
- **每晚自动停机**：部分订阅会在夜间自动停止 AKS 和 PostgreSQL，使用前请先运行 `scripts/00-resume.sh`。

- **产物只能在 VNet 内下载**：Blob 没有公网入口，所以在 VNet 外的工作站上，直接读写存储的 `osmo` 命令无法使用。
- **SAS 轮换器每 3 天重启一次 OSMO 的 Pod**：OSMO 不会自动重新加载 Secret。如果 CronJob 连续失败超过约 7 天，产物上传就会失败。可以用 `kubectl get cronjob,jobs -n osmo` 检查运行情况。
- **Spot 节点可能被回收**：节点被回收时，上面正在运行的工作流会中断。
- **authz 使用 `sslmode=require`**：连接是加密的，但不校验 PostgreSQL 的服务端证书。

## OSMO 6.4 发布之后

1. 迁移到统一的 `osmo` chart，参考上游的 `deployments/upgrades/6_3_to_6_4_upgrade.md`。
2. 把 `workflow_data` 改回只配置 endpoint 的凭据（使用 Workload Identity），并删除 SAS 轮换器。
3. 重新确认是否还需要配置重复的 JWT provider 来规避问题 1。
