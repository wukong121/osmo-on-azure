# OSMO on Azure 操作手册

日常使用和运维 OSMO 的常用命令。所有命令都在**部署机**上执行，也就是装有 `az`、`kubectl`、`terraform` 和 `osmo` CLI，并且出口 IP 在 `admin_ip_cidrs` 里的那台机器。部署步骤见 [deploy/README.zh-CN.md](../deploy/README.zh-CN.md)。

文中用到的占位符：

| 占位符 | 含义 | 查询方式 |
|---|---|---|
| `<OSMO_HOSTNAME>` | OSMO 的公网 HTTPS 域名（第 5 步配置） | `kubectl get ingress osmo-public -n osmo -o jsonpath='{.spec.rules[0].host}'` |
| `<workflow-id>` | 工作流 ID，例如 `poc-gpu-t4-4` | `osmo workflow list` |

---

## 1. 每天开始前：恢复环境

部分订阅（如 MCAPS）每晚会自动停止 AKS 和 PostgreSQL，停机期间所有命令都会报连接失败。每天第一次使用前执行一次：

```bash
cd ~/Codes/osmo-on-azure
deploy/scripts/00-resume.sh
```

这个脚本会做三件事：启动 AKS 和 PostgreSQL；等待 Workload Identity webhook 就绪；重启 OSMO 各组件。

单独检查运行状态：

```bash
az aks show -g <资源组> -n <AKS 名称> --query powerState.code -o tsv          # Running / Stopped
az postgres flexible-server show -g <资源组> -n <PG 名称> --query state -o tsv  # Ready / Stopped
```

资源组、AKS 和 PostgreSQL 的名称可以用 `terraform -chdir=infra/terraform output` 查看。

---

## 2. 登录 OSMO

### 通过公网域名（推荐）

```bash
osmo login https://<OSMO_HOSTNAME> --method token \
  --token-file <(kubectl get secret osmo-default-admin -n osmo -o jsonpath='{.data.password}' | base64 -d)
```

登录后 CLI 会保存会话。之后如果提示 token 过期，重新执行这条命令即可。

### 通过 port-forward（没有配置域名时）

```bash
kubectl port-forward -n osmo svc/osmo-gateway 9000:80 &
osmo login http://127.0.0.1:9000 --method token \
  --token-file <(kubectl get secret osmo-default-admin -n osmo -o jsonpath='{.data.password}' | base64 -d)
```

### 签发个人 token（可选）

默认管理员 token 不会过期。如果要把访问权限交给别人，或者在其他机器上使用，可以签发一个有过期时间、可以吊销的 token：

```bash
osmo token set <token名称> -e 2026-12-31 -d "说明" -t json | jq -r .token > ~/<token名称>.token
chmod 600 ~/<token名称>.token
osmo token list                    # 查看已签发的 token
osmo token delete <token名称>      # 吊销
```

### 浏览器登录（Web UI，需已完成部署第 6 步 Keycloak）

浏览器打开 `https://<OSMO_HOSTNAME>`，页面会跳转到 Keycloak 登录页，用邮箱和密码登录。首次登录时会要求修改初始密码。

### 用户与角色管理（Keycloak）

管理控制台地址：`https://<OSMO_HOSTNAME>/auth/admin`。登录后左上角切换到 realm **osmo**。

| 操作 | 方法 |
|---|---|
| 查看初始密码 | 在运行过 06 脚本的机器上执行 `cat ~/.osmo-keycloak-initial-passwords`。这些都是临时密码，首次登录时必须修改 |
| 管理员登录控制台 | 初始管理员账号存放在 Secret 里：`kubectl get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.username}' \| base64 -d`（把 `username` 换成 `password` 即可读取密码）。这是临时管理员，首次登录后建议在 master realm 中创建正式管理员并开启 OTP，然后删除这个临时账号 |
| 新增用户 | 控制台 → Users → Add user（用户名和邮箱都填写邮箱地址）→ Groups 加入 `osmo-users` 或 `osmo-admins` → Credentials 设置临时密码 |
| 调整角色 | 修改用户所属的组：`osmo-admins` 对应 osmo-admin，`osmo-users` 对应 osmo-user。用户需要重新登录才能生效（ID token 有效期内仍沿用旧角色） |
| 重置密码 / 禁用用户 | 控制台 → Users → 选择用户 → Credentials（Reset password）或者关闭 Enabled 开关 |
| 用户自助修改密码 | 访问 `https://<OSMO_HOSTNAME>/auth/realms/osmo/account` |

> 浏览器会话的 OSMO 角色只来自 Keycloak 的组。`osmo user update --add-roles` 只对 OSMO 签发的 token 生效，对浏览器用户不起作用。

---

## 3. 查看调度记录

```bash
osmo workflow list                                   # 最近 20 条（默认只显示自己提交的）
osmo workflow list -a -c 50 -o desc                  # 所有用户、最近 50 条、最新的在最上面
osmo workflow list -s FAILED RUNNING                 # 按状态筛选
osmo workflow list --submitted-after 2026-11-05      # 按提交日期筛选
osmo workflow list -n gpu                            # 名称中包含 gpu 的工作流
osmo workflow list -p default                        # 指定资源池
```

常见的状态：`PENDING`、`WAITING`、`RUNNING`、`COMPLETED`、`FAILED`、`FAILED_CANCELED`、`FAILED_IMAGE_PULL`、`FAILED_EVICTED`（Spot 节点被回收）、`FAILED_QUEUE_TIMEOUT`、`FAILED_EXEC_TIMEOUT`。

> 列表里的 Overview 链接是集群内部地址，浏览器打不开。Web UI 要接入 Entra ID 后才能使用，在此之前请用下面的命令查看详情。

## 4. 查看单个工作流

```bash
osmo workflow query <workflow-id>                    # 状态和各任务情况（加 -v 显示重试记录）
osmo workflow events <workflow-id>                   # 调度事件：分配到哪个节点、拉镜像、启动
osmo workflow logs <workflow-id>                     # 任务日志（实时流式输出）
osmo workflow logs <workflow-id> -t <任务名> -n 50   # 指定任务，只看最后 50 行
osmo workflow logs <workflow-id> --error             # 失败任务的错误日志
osmo workflow spec <workflow-id>                     # 当时提交的工作流 YAML
```

## 5. 查看资源

```bash
osmo pool list                                       # 资源池状态（ONLINE/OFFLINE）、GPU 用量
osmo resource list -p default                        # 每个节点的 CPU、内存、GPU 用量
osmo resource list -p default -m free                # 只看空闲资源
osmo config show BACKEND default                     # backend 状态（online、最近一次心跳）
```

## 6. 提交与取消

在仓库根目录执行：

```bash
osmo workflow submit deploy/workflows/hello.yaml --pool default              # CPU 任务
osmo workflow submit deploy/workflows/storage-roundtrip.yaml --pool default  # 产物上传、下载
osmo workflow submit deploy/workflows/gpu-t4.yaml --pool default             # T4 GPU 任务
osmo workflow submit deploy/workflows/isaaclab-cartpole.yaml --pool default  # Isaac Lab 3.0 headless 训练（Cartpole，T4）
osmo workflow submit deploy/workflows/mujoco-sim.yaml --pool default         # MuJoCo headless 仿真（CPU 节点池）
osmo workflow submit deploy/workflows/gazebo-sim.yaml --pool default         # Gazebo Harmonic headless 仿真（CPU 节点池）
osmo workflow validate <工作流.yaml> --pool default                          # 只校验，不提交
osmo workflow cancel <workflow-id>
osmo workflow restart <workflow-id>                                          # 重跑失败的工作流
```

一键跑完全部验收：`deploy/scripts/04-verify.sh`；也可以只跑其中几项：`deploy/scripts/04-verify.sh hello gpu`；仿真示例：`deploy/scripts/04-verify.sh isaaclab mujoco gazebo`。

> 工作流里通过 `files:` 引用的文件（例如 `files/mujoco_sim.py`）是相对于工作流 YAML 所在目录解析的，所以要用 CLI 提交（UI 不支持文件注入）。

所有 `osmo` 命令都支持加 `-t json` 输出 JSON，方便用 `jq` 处理。

---

## 7. Kubernetes 视角

```bash
kubectl get nodes -L kubernetes.azure.com/agentpool,nvidia.com/gpu.product   # 节点、所属节点池、GPU 型号
kubectl get pods -n osmo-workflows -o wide                                   # 正在运行的作业 Pod 及其所在节点
kubectl get events -n osmo-workflows --sort-by=.lastTimestamp                # 调度和拉镜像的事件
kubectl get pods -n osmo                                                     # OSMO 控制面组件
kubectl get pods -n osmo-operator                                            # backend operator
kubectl get pods -n gpu-operator -o wide                                     # GPU 驱动、device plugin
kubectl get cronjob,jobs -n osmo                                             # SAS 轮换器（OSMO 6.3.1 的变通方案）
```

作业 Pod 运行结束后会被清理掉，历史记录要用 `osmo workflow ...` 查询。

## 8. Azure 门户：查看作业日志

打开 Log Analytics 工作区（`terraform output` 里的 `log-...`），进入**日志**页面，执行下面的查询。日志会一直保留，集群停机时也能查：

```kusto
ContainerLogV2
| where PodNamespace == "osmo-workflows"
| where ContainerName !in ("osmo-ctrl", "osmo-init")
| project TimeGenerated, PodName, ContainerName, LogMessage
| order by TimeGenerated desc
```

## 8.1 AzureML：查看训练、模型和验证结果

闭环工作流（`deploy/scripts/07-azureml-loop.sh`，说明见 [azureml-loop.md](azureml-loop.md)）把记录写进 AzureML 工作区（`terraform output aml_workspace_name`）。打开 https://ml.azure.com 并选择该工作区：

- **Jobs → 实验 `cartpole-rl`**：训练运行的奖励、损失曲线和超参数；子运行 `sim2sim-mujoco` 是仿真验证结果。
- **Models → `cartpole-policy`**：按标签 `sim2sim_validation` 查看每个版本是否通过验证，`osmo_workflow_id` 指向产生它的 OSMO 工作流。
- **Data → `cartpole-sim2sim-scenarios`**：验证集版本。

命令行查看：

```bash
az ml model list -n cartpole-policy -g <资源组> -w <工作区> --query "[].{v:version,result:tags.sim2sim_validation,rate:tags.sim2sim_success_rate,wf:tags.osmo_workflow_id}" -o table
```

AzureML 存储和数据湖只走私网，从 VNet 外无法在 Studio 里预览产物文件，但指标、标签和血缘可以正常查看。

---

## 9. 成本控制

| 操作 | 方法 |
|---|---|
| CPU 作业节点池 | `cpu_node_min_count`（默认 1）和 `cpu_node_max_count`（默认 3）。设为 0 后无法提交 CPU 任务 |
| 暂时不用 GPU | 在 `infra/terraform/terraform.tfvars` 中设置 `gpu_node_min_count = 0`，然后执行 `terraform apply`。注意：节点池缩到 0 台后无法提交 GPU 任务 |
| 恢复使用 GPU | 设置 `gpu_node_min_count = 1`，然后执行 `terraform apply`。新节点安装驱动大约需要 5–10 分钟 |
| 下班后手动停机 | `az aks stop ...`、`az postgres flexible-server stop ...`；下次使用时执行 `00-resume.sh` |

## 10. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| 连接超时或 DNS 解析失败 | 集群已停机 | 执行 `deploy/scripts/00-resume.sh` |
| `There are no resources in platform t4` | GPU 节点池当前是 0 台 | 设置 `gpu_node_min_count = 1`，然后 `terraform apply` |
| `Value ... too high for CPU` | CPU 节点池 `npcpu` 的空闲 CPU 不够 | `osmo resource list -p default -m free` 查看空闲资源；调大 `cpu_node_min_count` 或换更大的 `cpu_node_vm_size`；或者减小工作流中 `cpu` 的申请量 |
| 新增节点后 `osmo resource list` 里看不到；或者节点明明空闲，提交时却报 `too high` | backend operator 的节点缓存过期了（例如还在统计一个已经在 OSMO 之外被删掉的 Pod） | `kubectl rollout restart deploy -n osmo-operator` |
| 工作流长时间停在 `PENDING` | 节点正在扩容、在拉镜像，或 Spot 容量不足 | 用 `osmo workflow events <id>` 和 `kubectl get events -n osmo-workflows` 排查 |
| `rl-train-validate` 的 register / validate 报 `AuthorizationFailed` 或 403 | `id-osmo` 的 AzureML 角色还没生效，或 `azureml.tf` 没有 apply | 确认 `terraform apply` 已完成；新角色分配可能需要几分钟生效 |
| `FAILED_EVICTED` 或 `FAILED_BACKEND_ERROR`（事件中有 `preempt`） | Spot 节点被回收 | 执行 `osmo workflow restart <id>` 重跑 |
| 产物上传失败（Blob 403 或 SAS 过期） | SAS 轮换器失败超过 7 天 | `kubectl get cronjob,jobs -n osmo`；手动触发一次：`kubectl create job --from=cronjob/osmo-sas-rotator sas-manual -n osmo` |
| `osmo` 命令报 `127.0.0.1:9000 Connection refused` | CLI 最后一次登录的是 port-forward 地址，而 port-forward 已经结束（例如没有配置公网域名时，`03`/`04` 脚本会临时开 port-forward；配置了域名后，脚本会自动改用域名） | 用公网域名重新登录（见第 2 节） |
| 浏览器登录后页面空白，或显示 “unable to load”（403） | 该用户在 Keycloak 中不属于 `osmo-users` / `osmo-admins` 组 | 在 Keycloak 控制台把用户加入相应的组，然后让用户退出并重新登录 |
| 浏览器页面报 `Jwt is expired` | 会话里的 ID token 已过期，但还没有被刷新（正常情况下 oauth2-proxy 每 10 分钟自动刷新一次） | 重新登录：访问 `https://<OSMO_HOSTNAME>/oauth2/sign_out`，或者清除站点 Cookie。如果反复出现，检查 Keycloak realm 的 token 有效期（15 分钟）是否仍然大于 oauth2-proxy 的 `cookieRefresh`（10 分钟） |
| 闲置一段时间后要求重新登录 | Keycloak 会话闲置超过 8 小时，或者总时长超过 12 小时 | 正常现象，重新登录即可 |
| 浏览器登录后又被跳回 Keycloak 登录页 | 密码错误、账号被禁用，或者 oauth2-proxy 刚重启 | 核对密码和账号状态，稍后重试 |
| `osmo login` 返回 401 | 用了错误的 token，或者 token 已过期 | 重新从 `osmo-default-admin` Secret 读取 token 后登录 |
| `osmo pool list` 显示 `OFFLINE` | backend operator 没有在运行 | `kubectl get pods -n osmo-operator`；执行 `00-resume.sh` 重启 |
