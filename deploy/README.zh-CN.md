# OSMO on Azure：OSMO 部署（Helm）

[English](README.md) | 简体中文

这里的脚本把 NVIDIA OSMO 6.3.1 部署到 [infra/terraform](../infra/terraform/README.zh-CN.md) 创建的 AKS 集群上，并接入同一份 Terraform state 里的 Azure 数据服务。

**状态（2026-11-05）**：已在 West US 3 部署完成，第一阶段的三项验收（`hello`、`storage`、`gpu`）全部通过。

## 组件与版本

| 组件 | Chart / 版本 | 命名空间 | 说明 |
|---|---|---|---|
| NVIDIA GPU Operator | `nvidia/gpu-operator` v26.7.2 | `gpu-operator` | T4 节点驱动 595.91.07；container toolkit v1.20.1（chart 默认版本）；nvidia 设为 containerd 默认运行时 |
| KAI Scheduler | `oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler` v0.14.9 | `kai-scheduler` | 与 OSMO 6.3.x 配套；关闭了 GPU runtimeClass 自动注入 |
| OSMO service | `osmo/service` 1.3.1（OSMO 6.3.1），release `osmo` | `osmo` | API、Router、Worker、Logger、Agent、UI、Envoy 网关、authz |
| OSMO backend operator | `osmo/backend-operator` 1.3.1，release `osmo-operator` | `osmo-operator` | 把 AKS 注册为 backend `default`；工作流 Pod 运行在 `osmo-workflows` |
| workflow-data SAS 轮换器 | [manifests/workflow-data-sas-rotator.yaml](manifests/workflow-data-sas-rotator.yaml) | `osmo` | 绕过 OSMO 6.3.1 bug 的 CronJob（原因见下文），升级到 OSMO 6.4 后删除 |

## 第一阶段设计

- **认证**：只使用 OSMO 签发的 token。
  - 关闭 oauth2-proxy。
  - 开启 authz：网关校验 OSMO JWT，并剥离客户端自带的身份头。
  - `admin` 用户用 `osmo/osmo-default-admin` Secret 里的 access token 登录。
  - backend operator 使用单独的 token，角色为 `osmo-backend`。
  - Web UI 需要 IdP 才能在浏览器里登录，所以第一阶段以 CLI 为主，下一步通过 oauth2-proxy 接入 Entra ID。
- **访问**：网关是 ClusterIP 服务，通过 `kubectl port-forward` 访问。这条路径走 AKS API，受 Entra ID 保护。
- **数据服务**：
  - PostgreSQL 走 TLS（authz 使用 `sslmode=require`）。
  - Redis 走 TLS，端口 10000。
  - 凭据在运行脚本时从 Terraform 的敏感输出读取，写入 Kubernetes Secret。Key Vault 仅私网访问，部分订阅会用策略强制要求这一点。
- **存储**：Blob 路径为 `azure://<account>/osmo/...`，只能经私有终结点访问，不使用账号密钥。
  - `workflow_log` 和 `workflow_app` 使用 Workload Identity，控制面使用 ServiceAccount `osmo/osmo`。
  - `workflow_data`（任务产物）使用定期轮换的、容器级的**用户委托 SAS**。这个 SAS 由 Entra ID 签发，不依赖账号密钥，原因见下文。
- **资源池 `default`**：
  - 平台 `default`：仅 CPU 任务，运行在系统节点池。
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
```

每个脚本都可以安全地重复执行。有两样东西只在第一次运行时生成，之后不会被覆盖：
- 默认管理员 token（`osmo/osmo-default-admin`）
- 主加密密钥 MEK（`osmo/mek-config`）

请务必备份 MEK。MEK 一旦丢失，PostgreSQL 里加密的数据就无法再读取。

## 使用 OSMO

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

只跑其中几项：`deploy/scripts/04-verify.sh hello storage`。

## 部署中发现的问题与修复

| # | 现象 | 原因 | 修复 |
|---|---|---|---|
| 1 | 网关端口拒绝连接，Envoy 日志报 `RequiresAny ... must contain at least 2 item(s)` | `osmo/service` 1.3.1 总是把兜底的 JWT 规则渲染成 `requires_any`，而只有一个 provider 时 Envoy 会拒绝这份配置 | 在 [values/osmo-service.yaml](values/osmo-service.yaml) 里把 OSMO 的 JWT provider 配置两次；第二阶段换成 Entra ID |
| 2 | CPU 任务卡在 `Init`，报错 `no runtime for "nvidia" is configured` | KAI 的 admission webhook 会给所有声明了 `nvidia.com/gpu` 的 Pod 加上 `runtimeClassName: nvidia`，而 OSMO 默认模板即使值为 0 也会声明这个资源 | KAI 设置 `admission.gpuPodRuntimeClassName: ""`；GPU 节点改为把 nvidia 设成 containerd 默认运行时 |
| 3 | Worker 报 `ClusterCrossSlotError` | Azure Managed Redis 在多分片 SKU 上使用 `EnterpriseCluster` 时，会拒绝跨 slot 的多 key pipeline | Redis 改为 `clustering_policy = "NoCluster"`（infra/terraform） |
| 4 | 任务产物上传报 `KeyError: 'access_key_id'` | OSMO 6.3.1 的 bug：osmo-ctrl 默认 workflow_data 凭据里一定有密钥。6.4 已修复但尚未发布；账号密钥又被订阅策略禁用 | `workflow_data` 改用用户委托 SAS，由 CronJob 每 3 天轮换一次（[manifests/workflow-data-sas-rotator.yaml](manifests/workflow-data-sas-rotator.yaml)） |
| 5 | GPU 容器启动失败，报 `No help topic for 'apply-cuda-memory-limits'` | container toolkit v1.17.8 是 microsoft/physical-ai-toolchain 为 operator v26.3 锁定的版本，对 operator v26.7 来说太旧 | 改用 chart 自带的 toolkit v1.20.1；GPU 节点运行 Ubuntu 22.04，在这个系统上运行稳定 |
| 6 | 提交 GPU 任务报 `There are no resources in platform t4` | OSMO 按现有节点校验资源，节点池缩到 0 时无法接收任务 | 测试期间设置 `gpu_node_min_count = 1`，闲置时改回 0 |

## 已知限制（第一阶段）

- **没有浏览器 UI 登录**：需要 IdP。下一步通过 `gateway.oauth2Proxy` 加 JWT provider 接入 Entra ID。
- **产物只能在 VNet 内下载**：Blob 没有公网入口，所以在 VNet 外的工作站上，直接读写存储的 `osmo` 命令无法使用。
- **SAS 轮换器每 3 天重启一次 OSMO 的 Pod**：OSMO 不会自动重新加载 Secret。如果 CronJob 连续失败超过约 7 天，产物上传就会失败。可以用 `kubectl get cronjob,jobs -n osmo` 检查运行情况。
- **Spot 节点可能被回收**：节点被回收时，上面正在运行的工作流会中断。
- **authz 使用 `sslmode=require`**：连接是加密的，但不校验 PostgreSQL 的服务端证书。

## OSMO 6.4 发布之后

1. 迁移到统一的 `osmo` chart，参考上游的 `deployments/upgrades/6_3_to_6_4_upgrade.md`。
2. 把 `workflow_data` 改回只配置 endpoint 的凭据（使用 Workload Identity），并删除 SAS 轮换器。
3. 重新确认是否还需要配置重复的 JWT provider 来规避问题 1。
