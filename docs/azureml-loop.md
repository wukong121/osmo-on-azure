# OSMO + AzureML 闭环：数据 → 仿真训练 → 模型注册 → 仿真验证

> 状态（2026-11-06）：已在 westus3 部署并端到端跑通。

## 1. 目标和分工

机器人团队通常已经有仿真和训练脚本，缺的是**把数据、训练、验证串起来并留下记录**的工具：哪个模型用了哪份数据、在哪个仿真器里验证过、结果如何。这里假设客户还没有实验管理和模型管理工具。

| 角色 | 组件 | 负责 |
|---|---|---|
| 执行 | NVIDIA OSMO（AKS） | 调度和运行仿真、训练、验证任务；GPU / CPU 资源；任务产物存到 Blob |
| 记录系统 | Azure Machine Learning 工作区 | MLflow 实验跟踪（指标、参数、产物）；模型注册表（版本、标签、血缘）；数据资产 |
| 数据 | ADLS Gen2 数据湖 | 机器人数据（这里放的是仿真验证集），注册为 AzureML 数据存储 `robotics_data` |

设计要点：

- **不在 AKS 上安装 AzureML 扩展。** 它依赖 Volcano，与 OSMO 使用的 KAI Scheduler 冲突，还要求 AKS 开启本地账号。OSMO 任务直接调用 AzureML 的 API（MLflow 和 `azure-ai-ml` SDK）。
- **全部使用 Workload Identity。** 所有 OSMO 任务 Pod 都以 `osmo-workflow` 服务账号运行，它联合到托管身份 `id-osmo`。这个身份拥有工作区的 `AzureML Data Scientist` 角色，以及 AzureML 存储和数据湖的 `Storage Blob Data Contributor` 角色。不用账号密钥，也不用 SAS。
- **数据组件只走私网。** AzureML 默认存储和数据湖都关闭了公网访问和 Shared Key，只能通过私有终结点访问。工作区本身也有私有终结点；它的公网端点保持开启，并受 Entra ID 和 RBAC 保护，便于在浏览器里使用 Studio。

## 2. 资源

由 `infra/terraform/azureml.tf` 创建：

| 资源 | 名称（默认） | 说明 |
|---|---|---|
| AzureML 工作区 | `mlw-osmo-poc-wus3` | Basic SKU，系统分配标识，默认存储用 Identity 访问 |
| Application Insights | `appi-osmo-poc-wus3` | 接入现有 Log Analytics |
| 工作区默认存储 | `stosmopocwus3ml<sfx>` | 存 MLflow 产物和模型文件；私有终结点：blob、file |
| 数据湖（ADLS Gen2） | `stosmopocwus3dl<sfx>`，容器 `robotics-data` | 模拟客户的机器人数据存储（PoC 与计算放在同一区域）；私有终结点：blob、dfs |
| 数据存储 | `robotics_data` | 把数据湖注册到工作区，使用 Identity 访问，不保存凭据 |
| Key Vault | 复用现有的 `kv-osmo-poc-wus3-<sfx>` | 工作区必需的依赖 |
| 私有 DNS 区域 | `privatelink.{api.azureml.ms, notebooks.azure.net, file.core.windows.net, dfs.core.windows.net}` | 链接到 VNet |

## 3. 流程

![OSMO + AzureML 闭环时序图](images/azureml-loop.png)

_UML 时序图：紫色区域是数据准备（每个数据版本一次），绿色区域是闭环工作流；`alt` 框是仿真验证门禁的两种结果。_

1. **数据准备**（`deploy/workflows/azureml-seed-data.yaml`，每个数据版本跑一次）
   - 把验证集上传到数据湖 `robotics-data/cartpole/sim2sim/<版本>/`：MuJoCo 版 Cartpole 模型 `cartpole.xml`，以及 100 个初始状态 `scenarios.json`。初始状态按 Isaac-Cartpole 的重置分布采样，随机种子固定。
   - 注册为 AzureML 数据资产 `cartpole-sim2sim-scenarios:<版本>`。
2. **训练**（`train`，T4）
   - Isaac Lab 3.0 headless（Newton 物理）用 RSL-RL PPO 训练 `Isaac-Cartpole`，默认 1024 个并行环境、150 次迭代，约 1.5 分钟。
   - 用 Isaac Lab 官方的 play 脚本把策略导出为 ONNX（导出完成后即停止回放）。
3. **登记**（`register`，CPU）
   - rsl_rl 只写 TensorBoard，所以这一步把 TensorBoard 指标回放到 AzureML 的 MLflow 运行（实验 `cartpole-rl`），并记录关键超参数。
   - 上传 ONNX 策略、checkpoint 和配置文件，注册模型 `cartpole-policy` 的新版本，打标签 `sim2sim_validation=pending`，并附上 `osmo_workflow_id`。
4. **仿真验证**（`validate`，CPU）
   - 通过 AzureML 数据资产找到数据湖中的验证集并下载。
   - 在 MuJoCo 中用 ONNX 策略跑 100 个回合，每个回合 5 秒（控制 60 Hz，物理 120 Hz，与 Isaac Lab 相同）。
   - 回合成功的条件：小车始终在 ±3 m 内（Isaac Lab 的终止边界），且最后 1 秒摆杆平均偏角小于 0.2 rad。
   - 结果写入一个新的 MLflow 运行（父运行是训练运行，并记录所用的数据资产版本），然后更新模型标签：`sim2sim_validation=passed|failed`、`sim2sim_success_rate`、`sim2sim_simulator`。
   - 成功率低于门限（默认 90%）时，任务失败，整个工作流显示为失败。

## 4. Sim2sim：MuJoCo 模型怎么对齐 Isaac Lab

`deploy/workflows/files/rl/cartpole.xml` 的参数取自 Isaac Lab 官方资产 `Robots/Classic/Cartpole/cartpole.usd` 和 `isaaclab_assets/robots/cartpole.py`：

| 项 | 值 |
|---|---|
| 小车 | 0.20 × 0.25 × 0.20 m 长方体，1 kg；滑轨限位 ±4 m |
| 摆杆 | 0.04 × 0.06 × 1.0 m 长方体，1 kg，质心在铰链上方 0.47 m |
| 驱动 | 滑轨隐式执行器：刚度 0、阻尼 10、力上限 400 N；动作缩放 100 |
| 观测 | `[小车位置, 摆角, 小车速度, 摆角速度]` |
| 时间步 | 物理 1/120 s，策略每 2 个物理步执行一次 |

USD 中小车沿 +Y 移动、摆杆绕 +X 转动；MJCF 中小车沿 +X 移动，铰链轴取 -Y，使摆角的正方向与 Isaac Lab 一致。

**这是同一个机器人在两个物理引擎之间的迁移验证（sim2sim），不是 sim2real。** 对复杂机器人，两个引擎在接触、摩擦和执行器建模上的差异会大得多，这正是需要独立仿真验证的原因。

## 5. 运行

前提：已 apply `infra/terraform`（包括 `azureml.tf`），并完成 `deploy/` 的第 1–3 步。

```bash
deploy/scripts/07-azureml-loop.sh            # 数据准备 + 闭环
deploy/scripts/07-azureml-loop.sh loop       # 只跑闭环（数据资产已存在）
DATASET_VERSION=2 deploy/scripts/07-azureml-loop.sh seed     # 发布新的数据版本
LOOP_SET="max_iterations=300 threshold=0.95" deploy/scripts/07-azureml-loop.sh loop
```

脚本从 Terraform 输出读取工作区信息，再通过 `osmo workflow submit --set-string` 传给工作流。也可以手动提交：

```bash
osmo workflow submit deploy/workflows/rl-train-validate.yaml --pool default \
  --set-string aml_subscription_id=<订阅 ID> aml_resource_group=<资源组> aml_workspace=<工作区>
```

可调参数（`default-values`）：`num_envs`、`max_iterations`、`threshold`、`experiment`、`model_name`、`dataset`（`name` 或 `name:version`）。

## 6. 在 AzureML Studio 中查看

打开 https://ml.azure.com ，选择工作区 `mlw-osmo-poc-wus3`：

- **Jobs → 实验 `cartpole-rl`**：每次训练对应一个运行 `train-<时间戳>`，包含奖励、回合长度、损失等曲线和超参数。仿真验证运行 `sim2sim-mujoco` 是它的子运行，包含成功率等指标。
- **Models → `cartpole-policy`**：每个版本的标签显示来源的 OSMO 工作流、训练器、仿真器和 sim2sim 结果，可以按 `sim2sim_validation=passed` 筛选可用的模型。
- **Data → `cartpole-sim2sim-scenarios`**：验证集的版本，以及它在数据湖中的位置。

注意：AzureML 存储和数据湖只能通过私网访问，所以从 VNet 外打开 Studio 时，指标、参数、标签和血缘都能正常显示，但**预览或下载产物文件会失败**。需要时从 VNet 内的跳板机访问，或者用 OSMO 任务读取。

## 7. 实测结果（2026-11-06）

| 步骤 | 结果 |
|---|---|
| 数据准备 | 上传 2 个文件到数据湖（私有终结点 + Workload Identity），注册数据资产 `cartpole-sim2sim-scenarios:1` |
| 训练 | T4 上 1024 环境 × 150 次迭代约 1.5 分钟，训练末期成功率 1.0、平均回合奖励约 4.93；ONNX 导出成功 |
| 登记 | 21 个 TensorBoard 指标、3150 个数据点写入 MLflow；注册 `cartpole-policy` |
| 仿真验证 | MuJoCo 3.17：100/100 回合成功，最终摆角平均 0.002 rad；模型标签更新为 `passed` |

完整闭环（工作流 `rl-train-validate-2`）从 train 开始到 validate 结束约 11 分钟，其中训练约 2 分钟，其余主要是任务间的产物上传 / 下载和 `pip install`。模型 `cartpole-policy:2` 标签为 `sim2sim_validation=passed`、`osmo_workflow_id=rl-train-validate-2`。Isaac Lab 默认使用固定随机种子，所以相同配置下重复训练得到的策略和验证指标完全一致。

T4 Spot 节点在训练中可能被抢占（实测遇到过一次）。被抢占的工作流会以 `FAILED_BACKEND_ERROR` 结束，重新提交即可。

## 8. 后续可扩展

- **Gazebo 验证**：需要 ROS 2 控制接口（ros2_control / gz bridge），适合腿式机器人等更复杂的模型。
- **镜像**：把 Python 依赖预装进镜像并推到 ACR，省去每个任务约 30–60 秒的 `pip install`。
- **数据位置**：客户数据在其他区域时，数据湖可以放在数据所在区域，再通过 AzureML 数据存储引用；训练位置按算力和合规要求选择。
- **模型发布**：在通过验证的模型版本上加审批流程（例如 Azure DevOps / GitHub Actions），再发布到边缘设备。
