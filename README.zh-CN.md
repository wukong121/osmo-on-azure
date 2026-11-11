# osmo-on-azure

[English](README.md) | 简体中文

在 Azure 上部署 NVIDIA OSMO，为具身智能和机器人团队提供云端仿真作业调度方案。

## 架构（PoC 第一阶段）

![OSMO on Azure 架构](docs/images/azure-architecture.png)

_连线说明：绿色 = 私网（VNet / Private Link）· 橙色虚线 = 公网入口（AKS API 仅放行管理 IP；Traefik HTTPS 入口对互联网开放，由 OSMO / Keycloak 认证保护） · 灰色 = 经 NAT 出网 · 蓝色点线 = 身份 / 监控。_

## 文档

| 文档 | 内容 |
|---|---|
| [docs/reference-repos.md](docs/reference-repos.md) | 参考仓库研读结论（NVIDIA/OSMO、microsoft/physical-ai-toolchain）：版本选择、PG TLS、可复用内容 |
| [docs/operations-guide.md](docs/operations-guide.md) | 操作手册：恢复环境、登录、查看调度记录和日志、资源查看、成本控制、常见问题 |
| [docs/azureml-loop.md](docs/azureml-loop.md) | OSMO + AzureML 闭环：数据湖 → T4 上 Isaac Lab 训练 → MLflow 实验跟踪和模型注册 → MuJoCo 和 Gazebo 中的 sim2sim 验证 |
| [docs/legged-sim2sim.md](docs/legged-sim2sim.md) | 点足双足机器人在 MuJoCo 和 Gazebo（厂商 ROS 2 部署栈）中的 sim2sim 大规模验证：场景在 CPU 池上分片并行，按摔倒率和速度跟踪门禁，在 AzureML 模型注册表中做冠军 / 挑战者晋级 |
| [docs/t4-feasibility.md](docs/t4-feasibility.md) | T4 GPU 运行 Isaac Lab / Isaac Sim / MuJoCo / Gazebo 的可行性评估 |
| [docs/images/](docs/images/) | Azure 部署架构图、OSMO + AzureML 闭环时序图、腿式机器人 sim2sim 时序图、OSMO 部署架构图、工作流时序图 |
| [infra/terraform/](infra/terraform/README.zh-CN.md) | Azure 基础设施：AKS（系统池、CPU 池、T4 Spot GPU 池）、私网数据组件、固定入口 IP、AzureML 工作区和机器人数据湖 |
| [deploy/](deploy/README.zh-CN.md) | OSMO 6.3.1 部署（GPU Operator、KAI、OSMO service、backend operator、Traefik、Keycloak）、验收检查与仿真示例 |

## 当前状态（PoC 第一阶段）

- **平台**：NVIDIA OSMO 6.3.1（开源版，chart `service` / `backend-operator` 1.3.1），部署在 West US 3 的 AKS 上，基础设施由 Terraform 管理。
- **算力**：
  - 系统节点池：运行平台组件。
  - CPU 节点池 `npcpu`：专门运行 OSMO 的 CPU 作业。
  - T4 Spot GPU 节点池 `npgput4`：运行 GPU 作业，驱动 595 由 GPU Operator 安装。
  - 作业由 KAI 调度。
- **网络**：
  - AKS API 走公网，只放行管理 IP。
  - PostgreSQL、Redis、Blob、Key Vault 只能经私网访问。
  - OSMO 通过 Traefik 发布到公网 HTTPS 域名，使用自有证书和固定 IP。
- **认证**：
  - Web UI：使用 Keycloak（官方 Operator），用户名 + 密码登录；OSMO 角色（`osmo-admin` / `osmo-user`）由 Keycloak 中的组决定。
  - CLI 和自动化：使用 OSMO access token。
- **已验证**：
  - 主链路：登录 → 提交 → 排队 → 调度 → 状态 → 日志 → 产物。
  - 仿真示例：
    - Isaac Lab 3.0 headless 训练（T4）
    - MuJoCo（CPU 池）
    - Gazebo Harmonic（CPU 池）
- **AzureML 闭环**（[docs/azureml-loop.md](docs/azureml-loop.md)）：
  - OSMO 负责执行，AzureML 负责记录实验（MLflow）、模型和数据资产。
  - 一个 OSMO 工作流完成：T4 上用 Isaac Lab 训练策略 → 在 AzureML 注册模型 → 在 MuJoCo 和 Gazebo 中做 sim2sim 验证，按成功率门禁给模型版本打上 passed / failed 标签。
  - 数据来自私网 ADLS Gen2 数据湖，注册为 AzureML 数据资产；全部使用 Workload Identity 访问。
- **腿式机器人 sim2sim 大规模验证**（[docs/legged-sim2sim.md](docs/legged-sim2sim.md)）：
  - 替代手柄驱动的手工 sim2sim：两套点足双足机器人预训练策略在 MuJoCo 中跑 1000–1200 个场景（速度指令 × 摩擦 × 负载 × 推力 × 延迟），切成 10 个 OSMO 任务并行。
  - 第二个仿真器直接运行厂商自己的 ROS 2 部署栈（Gazebo Classic + ros2_control + C++ RL 控制器），跑一个场景子集；镜像在集群内构建，存放在私有 ACR；模型必须在两个仿真器中都通过。
  - 按摔倒率和速度跟踪做门禁，决定哪个版本晋级 `stage=production`（冠军 / 挑战者）；场景集升级后对所有已注册模型重新验证。
- **已知限制**：见 [deploy/README.zh-CN.md](deploy/README.zh-CN.md#已知限制第一阶段)。例如，在 OSMO 6.4 发布之前，workflow-data 需要依赖 SAS 轮换器这一变通方案；订阅每晚会自动停机。
