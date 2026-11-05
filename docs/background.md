# 项目背景：osmo-on-azure

> 最后更新：2026-11-05 ｜ 负责人：王一行（Peter Wang），Microsoft Solution Engineer

## 1. 项目概述

`osmo-on-azure` 是一个**基于 Azure 部署 NVIDIA OSMO** 的解决方案项目，目标是为具身智能客户提供**云端仿真作业调度**能力。

- **首个目标客户**：逐际动力（LimX Dynamics）
- **定位**：仓库内容保持**客户中立**，沉淀为可复用的方案资产，后续可推广至其他具身智能 / 机器人客户
- **中文方案名**：基于 Azure 的具身智能仿真作业调度平台（OSMO on Azure）
- **商业目标**：以“仿真作业调度平台”为切入点，把 Azure GPU 算力引入客户的研发流程

## 2. 客户背景：逐际动力 LimX Dynamics

| 项目 | 内容 |
|---|---|
| 中文名 | 逐际动力 |
| 英文名 | LimX Dynamics（注意拼写：Lim**X**，不是 LinX） |
| 行业 | 具身智能 / 通用机器人 |
| 主要方向 | 足式机器人、人形机器人的运动智能与具身智能 |

### 2.1 现有仿真栈

主流仿真器都在用：

- **NVIDIA Isaac**（Isaac Sim / Isaac Lab）
- **Gazebo**
- **MuJoCo**

→ 调度平台需要**同时支持多种仿真器**的容器化作业，不能只绑定 Isaac。

### 2.2 现有算力

- 本地 GPU 机器
- 金山云（Kingsoft Cloud）GPU 云主机

### 2.3 现状与痛点

**目前没有作业调度平台**，仿真作业靠人工流转：

```
研发提出仿真作业需求
      ↓
IT 手工开机器（本地 or 金山云）
      ↓
研发登录到对应机器上，手动跑仿真任务
```

由此带来的问题：

- 资源申请靠人工，周期长，研发要等
- 作业没有统一提交、排队、监控和记录，难以批量或并行跑实验
- GPU 资源分散在本地和金山云，没有统一视图，利用率低，可能有闲置浪费
- 研发要自己管理机器环境，难以复现

## 3. 技术背景：NVIDIA OSMO

NVIDIA OSMO 是面向 Physical AI / 机器人开发的云原生工作流编排平台，基于 Kubernetes 运行，可以统一调度以下工作负载：

- 合成数据生成（SDG）
- 模型训练（含强化学习）
- 软件在环（SIL）/ 硬件在环（HIL）测试与验证

它支持跨多个计算集群（本地或云上）编排多阶段工作流。

**许可**：客户**没有 OSMO 企业 License**，本项目使用开源版本（[NVIDIA/OSMO](https://github.com/NVIDIA/OSMO)）。

## 4. PoC 方案

### 4.1 PoC 目标

**验证 OSMO 能否把仿真作业调度到 Azure 上的多个 GPU 算力上。**

### 4.2 已确定的技术选型

| 项 | 决定 |
|---|---|
| 编排平台 | NVIDIA OSMO（开源版） |
| 计算 | Azure Kubernetes Service（AKS）+ GPU 节点池 |
| IaC 工具 | **Terraform** |
| Azure 区域 | **West US 3（westus3）** |
| GPU | **NVIDIA T4（`Standard_NC*as_T4_v3` 系列）**。测试订阅在 westus3 只能开出这个系列。Isaac 类作业建议用 NC8as / NC16as，NC4as 只有 4 核 / 28 GB，偏紧 |
| OSMO 版本 | **6.3.1**（最新正式发布版）：chart 用 `service` 和 `backend-operator` 1.3.1。6.4 目前只有 git tag，还没有发布 chart 和镜像（详见 [reference-repos.md](reference-repos.md)） |
| PostgreSQL TLS | 保持开启（`require_secure_transport=on`），已对照 6.3.1 源码确认兼容 |
| 网络 | AKS API Server 第一阶段可以走公网（需要限制来源 IP）。**数据相关组件**（PostgreSQL、Redis、Blob、Key Vault、ACR）**必须走私网**（Private Endpoint / VNet 注入，并关闭公网访问） |
| 数据合规 | 数据可以出境 |

### 4.3 待细化

- GPU 节点数量和具体规格（NC4as / NC8as / NC16as）
- 存储方案：第一阶段用 Blob 存工作流数据、日志和产物。Azure Files / Managed Lustre 视仿真数据规模再定
- 研发怎么访问 OSMO UI/API：第一阶段用 port-forward 或内部 LB，正式方案待定
- 认证：第一阶段先用 dev 模式或管理员 token 跑通主链路，再通过 oauth2-proxy 接 Entra ID（OIDC）
- 验证用例：分别用 Isaac、Gazebo、MuJoCo 准备示例仿真作业
- 后续阶段：与客户本地 / 金山云 GPU 集群做混合调度（不在 PoC 范围内）

### 4.4 第一阶段成功标准

**跑通 OSMO 主链路，基础调度功能验证通过。** 对照 [工作流时序图](images/osmo_workflow_sequence.svg) 和 [部署架构图](images/osmo_deployment_architecture.svg) 逐项验证：

| # | 阶段 | 验证点 |
|---|---|---|
| 1 | 认证与授权 | 用户登录拿到 token，CLI 用 token 访问 API |
| 2-3 | 提交与排队 | `osmo workflow submit ... --pool <gpu-pool>` 通过校验，写入 PostgreSQL，进入 Redis 队列 |
| 4-5 | 分配与创建资源 | Worker 从队列取出作业，Backend Operator 在 AKS 的 T4 节点上创建 Pod（经过 KAI 调度） |
| 6 | 状态监控 | Pod 状态变化能回传，并在 CLI/UI 中看到 |
| 7 | 日志流 | `osmo workflow logs` 能实时看到容器日志 |
| 8 | 完成 | 任务结束，产物上传到 Blob，资源清理完成，状态显示为 completed |

基础用例：OSMO 自带的 `verify-hello`（CPU）、`verify-gpu`（`nvidia-smi`）、`verify-object-storage`。在此基础上，再补充以下仿真示例：
- Isaac Lab 3.0（Newton 后端，headless 训练）
- MuJoCo
- Gazebo

Isaac Sim 的 RTX 渲染和相机类作业在 T4 上能不能跑还不确定，第一阶段只作为探索项，不算成功标准，见 [t4-feasibility.md](t4-feasibility.md)。

> 架构图里的 Keycloak 是 OIDC IdP 的一种选择。OSMO 6.3.1 用 oauth2-proxy 接通用 OIDC，也可以换成 Entra ID。

## 5. 参考资料

- [microsoft/physical-ai-toolchain](https://github.com/microsoft/physical-ai-toolchain)：微软的 Physical AI 工具链参考实现
- [NVIDIA/OSMO — Azure Terraform 示例](https://github.com/NVIDIA/OSMO/blob/main/deployments/terraform/azure/example/README.md)：OSMO 官方的 Azure Terraform 部署示例
- 研读结论：[reference-repos.md](reference-repos.md)
- 架构图：[部署架构](images/osmo_deployment_architecture.svg)、[工作流时序](images/osmo_workflow_sequence.svg)

## 6. 待确认事项

- [x] 客户当前的仿真栈 → Isaac、Gazebo、MuJoCo
- [x] 客户现有算力 → 本地 GPU 机器 + 金山云
- [x] 目标 Azure 区域 → westus3
- [x] OSMO 许可 → 没有企业 License，用开源版
- [x] IaC 工具 → Terraform
- [x] westus3 的 GPU SKU → 测试订阅只能开 NC*as_T4_v3（T4）
- [x] 数据合规与网络要求 → 数据可以出境；AKS 可以走公网，数据组件走私网
- [x] 第一阶段成功标准 → 跑通主链路（见 4.4）
- [ ] PoC 时间线
- [x] 研读两个参考仓库 → 见 [reference-repos.md](reference-repos.md)
- [x] OSMO 版本 → 6.3.1（6.4 还没有发布 chart 和镜像）
- [x] T4 可行性 → Isaac Lab 3.0 Newton headless、MuJoCo、Gazebo 可行；Isaac Sim 渲染不确定（见 [t4-feasibility.md](t4-feasibility.md)）
- [ ] 拿到 T4 机器后按 t4-feasibility.md 的清单实测
- [x] PostgreSQL TLS → 可以开启
