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

### 4.3 待细化

- GPU 型号与数量（需结合 westus3 的可用 SKU 和订阅配额）
- 存储方案（Blob / Azure Files / Azure Managed Lustre）
- 网络与访问方式（公网 / 私有网络、客户研发怎么访问 OSMO）
- 验证用例：分别用 Isaac、Gazebo、MuJoCo 准备示例仿真作业
- 后续阶段：与客户本地 / 金山云 GPU 集群做混合调度（不在 PoC 范围内）

## 5. 参考资料

- [microsoft/physical-ai-toolchain](https://github.com/microsoft/physical-ai-toolchain)：微软的 Physical AI 工具链参考实现
- [NVIDIA/OSMO — Azure Terraform 示例](https://github.com/NVIDIA/OSMO/blob/main/deployments/terraform/azure/example/README.md)：OSMO 官方的 Azure Terraform 部署示例

## 6. 待确认事项

- [x] 客户当前的仿真栈 → Isaac、Gazebo、MuJoCo
- [x] 客户现有算力 → 本地 GPU 机器 + 金山云
- [x] 目标 Azure 区域 → westus3
- [x] OSMO 许可 → 没有企业 License，用开源版
- [x] IaC 工具 → Terraform
- [ ] westus3 的 GPU SKU 可用性和订阅配额
- [ ] 数据合规与网络要求（数据是否可以出境、是否需要私有网络）
- [ ] PoC 的时间线和成功标准（具体验证哪些指标）
- [ ] 详细阅读两个参考仓库，确定复用哪些内容
