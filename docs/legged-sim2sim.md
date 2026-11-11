# 点足双足机器人 sim2sim 大规模验证：OSMO 并行仿真 + AzureML 门禁

> 状态（2026-11-10）：已在 westus3 端到端跑通，包括冠军 / 挑战者晋级、门禁拦截、数据升级后的重新验证，以及 MuJoCo + Gazebo（ROS 2）双仿真器交叉验证。

## 1. 要解决的问题

腿式机器人的策略在 Isaac Gym / Isaac Lab 里训练好后，通常要先在另一个物理引擎（如 MuJoCo）里做 sim2sim 验证，再上真机。很多团队的做法是手工的：启动仿真器，用手柄发速度指令，看机器人会不会摔，摔了就复位再试。这样做有几个问题：

- 一次只能看一个场景，覆盖不到摩擦、负载、被推、控制延迟这些条件的组合。
- 没有记录，说不清某个模型在什么条件下验证过、结果如何。
- 没法比较：新模型比生产模型好还是差，靠印象判断。

[AzureML 闭环](azureml-loop.md) 用 Cartpole 证明了流水线能跑通。本示例把同一套机制用到一个真实的双足机器人上：

| 价值 | 做法 |
|---|---|
| 手工 → 自动化、批量化 | 1000+ 个场景（速度指令 × 摩擦 × 负载 × 推力 × 延迟），切成 N 个 OSMO 任务在 CPU 池上并行，结果全部留档 |
| 门禁拦住真实的 sim2sim 差距 | 按训练分布内场景的摔倒率和速度跟踪误差判定，按扰动维度拆解失败原因 |
| 冠军 / 挑战者 | 新模型必须通过门禁，并且不比当前生产模型差，才能晋级 `stage=production` |
| 数据版本驱动重新验证 | 场景集升级（v1 → v2）后，对所有已注册模型重新验证，血缘可追溯 |
| 多仿真器交叉验证，接上现有工具 | MuJoCo（复现的控制循环，快、确定性）+ Gazebo Classic（厂商自己的 ROS 2 部署栈：ros2_control 硬件插件 + C++ RL 控制器，和真机上跑的是同一套代码）；必须在两个仿真器中都通过 |
| 弹性算力 | CPU 节点池按需扩容（实测 1 → 3 个节点），空闲后自动缩回 |

## 2. 机器人和策略

示例面向使用 rsl_rl 训练、导出为 `policy.onnx` + `encoder.onnx` + `params.yaml` 的**点足双足机器人盲走速度跟踪策略**（6 个关节：每条腿 abad / hip / knee）。机器人模型（MJCF + 网格）和策略都从 git 仓库获取，地址在提交脚本的 `legged.env` 中配置（模板见 `deploy/scripts/legged.env.example`），仓库本身不包含任何机器人资产。

`deploy/workflows/files/legged/pointfoot_sim.py` 用官方 `mujoco` Python 包复现了这类机器人常见的部署控制循环，不需要厂商 SDK、进程间通信或手柄：

| 项 | 值 |
|---|---|
| 物理 / 控制 / 策略频率 | 1 kHz / 500 Hz / 50 Hz（decimation 10） |
| PD | 每个物理步 `Kp*(q*-q) - Kd*dq`，增益和力矩上限取自 `params.yaml` |
| 观测（30 维） | 机身角速度、投影重力、关节位置（相对默认姿态）、关节速度、上一步动作、步态时钟 sin/cos、步态参数（4） |
| Encoder | 10 帧观测历史（300 维）→ 机身线速度估计（3 维） |
| Policy 输入 | `[encoder 输出, 观测, 速度指令 (vx, vy, wz)]` → 6 个关节位置偏移 |
| 关节顺序 | Isaac Gym 版按腿排列；Isaac Lab 版按关节类型交错，由模型的 `rl_type` 决定映射 |
| 摔倒判定 | 机身高度 < 0.45 m、倾角 > 1 rad，或机身碰地 |
| 热身 | 复位后先零指令原地踏步 2 s（像操作员先启动策略再推摇杆），之后才是场景时间 0；热身期间摔倒算作摔倒 |
| 速度跟踪误差 | 0.5 s 滑动平均后的机身水平速度（航向坐标系）与指令之差的 RMSE；跳过场景开始后 1 s、指令切换后 0.5 s、被推后 1.5 s |

摔倒判定和误差计算在 `episode_metrics.py` 中，MuJoCo 和 Gazebo 共用同一套规则。

复现的正确性：零指令下两套公开发布的预训练策略 10 秒的漂移分别约 1.6 m 和 0.7 m，与厂商公布的实测范围（0.7–1.7 m）一致。仿真是确定性的，MuJoCo 3.17 和 4.0 的摔倒判定逐回合一致。

### 2.1 第二仿真器：Gazebo（ROS 2）

Gazebo 这一侧不复现控制循环，而是直接运行厂商开源的 ROS 2 部署栈：Gazebo Classic 11（ODE，2 ms 步长）+ ros2_control 硬件插件（经厂商 SDK 的仿真库连接）+ C++ RL 控制器（ONNX 推理，订阅 `/cmd_vel`）。它和真机上用的控制器是同一份代码，所以这一侧同时验证了“部署软件栈 + 另一个物理引擎”。

| 项 | 做法 |
|---|---|
| 镜像 | `deploy/images/legged-gazebo-ros2/Dockerfile`：`osrf/ros:iron-desktop-full` + Gazebo Classic + ONNX Runtime 1.10 + 四个厂商仓库（地址作为构建参数，来自 `legged.env`）编译。由 `build-image.yaml` 在集群内用 kaniko 构建（无需特权和 Docker 守护进程），通过 Workload Identity 推到私有 ACR（约 4 分钟） |
| 每个场景 | 一套全新进程：xacro → URDF（按场景改脚部摩擦 `mu1/mu2`、机身质量，注入 p3d 真值插件）→ gzserver 暂停启动 → 生成机器人 → 启动厂商硬件节点（6 s 后自动启动控制器）→ 控制器站立阶段结束时恢复物理 |
| 驱动 | `gazebo_episode.py`（rclpy）：按场景时间发布 `/cmd_vel`（除以控制器的 `user_cmd_scales`），用 `/apply_link_wrench` 施加推力，50 Hz 记录机身真值。推力请求的 `start_time` 必须填当前仿真时间：插件按 `start_time + duration` 计算结束时间，留空（0）时任务会被当作已过期直接丢弃，而服务照样返回成功。每个回合都记录推力调用结果和被推后的速度峰值，便于发现这类问题 |
| 实时性 | 控制器按墙钟 500 Hz 运行，Gazebo 必须实时（实时因子 1.0）；每个回合记录实时因子，低于 0.9 的回合无效 |
| 启动失败 | Gazebo 中从静止起步时，相当一部分回合在恢复物理后约 0.31 s 摔倒（时间点固定，与指令无关，摩擦越低越多；MuJoCo 中没有这种现象）。恢复物理后 0.5 s 内的摔倒记为启动失败，自动重试（最多 5 次），单独统计；之后的摔倒（包括热身期间）都算真实摔倒。5 次都启动失败的回合记为无效，门禁按场景组报告无效回合数 |
| 隔离 | `ROS_AUTOMATIC_DISCOVERY_RANGE=LOCALHOST` + 只走 UDP 的 Fast DDS 配置：同一网络中的分片不会互相发现节点（否则一个分片的 `/cmd_vel` 会被另一个分片的控制器收到） |
| 规模 | 实时仿真，每个 20 s 场景连同启动约 35 s，每个分片 2 CPU。默认跑 201 个场景的子集：120 个分布内（含组合扰动）+ 81 个分布外（摩擦、负载、推力各 27 个），按场景组均匀抽取 |
| 限制 | 厂商控制器无法注入观测延迟，Gazebo 子集跳过延迟维度；ROS 2 Iron 和 Gazebo Classic 都已停止维护（apt 源是 Iron 的冻结快照），镜像预构建后不受影响 |

## 3. 场景集

`scenarios.py` 按固定随机种子生成。每个场景 20 秒，含 4 段 5 秒的速度指令（站立 / 前后 / 侧移 / 转向 / 混合，范围 vx ±0.75 m/s、vy ±0.5 m/s、wz ±0.25 rad/s，即手柄的指令范围），再叠加物理扰动：

| 扰动 | 训练分布内 | 分布外 |
|---|---|---|
| 地面摩擦 | 0.4–1.2 | 0.15–0.4 |
| 机身附加质量 | -1 – +2 kg | 2–6 kg |
| 推力（0.1 s，水平随机方向） | 0–100 N（约 10 N·s） | 100–300 N |
| 观测延迟 | 0–10 ms | 20–60 ms |

| 版本 | 内容 |
|---|---|
| v1（1000 个） | 600 个分布内（四个扰动都在范围内随机）+ 400 个分布外（每个维度 100 个：只把这一个维度推到范围外，其余保持标称值，便于归因） |
| v2（1200 个） | v1 + 200 个“组合扰动”：滑地面 + 负载 + 被推 + 延迟同时出现，每一项都还在训练分布内，模拟现场事故中的组合工况 |

分布内的范围参照该类机器人训练时的域随机化设置。

## 4. 流程

![点足 sim2sim 大规模验证时序图](images/legged-sim2sim.png)

_UML 时序图：紫色区域是准备（每个场景集版本 / 策略发布一次），绿色区域是验证；`par` 框里的任务并行执行，`alt` 框是门禁的三种结果。_

| 工作流 | 任务 | 说明 |
|---|---|---|
| `legged-seed.yaml` | `seed-scenarios` | 拉取机器人 MJCF，生成场景集，上传到数据湖 `robotics-data/legged/pointfoot/sim2sim/<版本>/`，注册数据资产 `pointfoot-sim2sim-scenarios:<版本>` |
| | `import-policies` | 拉取导出的策略，每种 `rl_type` 注册为模型 `pointfoot-policy` 的一个新版本（文件存为 MLflow 运行 `import-*` 的产物，标签记录来源仓库和 commit） |
| `legged-validate.yaml` | `fetch` | 从模型注册表解析被测模型并下载：`name:version` 为挑战者，自动加上当前冠军（`stage=production`）；`name:all` 为全部版本。同时下载数据资产 |
| | `validate-0` … `validate-N-1` | Jinja `{% for %}` 生成 N 个分片（默认 10 个，各 1 CPU），每片对所有被测模型跑 `id % N == i` 的场景，输出逐回合 `episodes.csv` |
| | `gazebo-0` … `gazebo-M-1` | M 个 Gazebo 分片（`GAZEBO_SHARDS`，默认 8 个，各 2 CPU，镜像来自私有 ACR），每片对所有被测模型跑 Gazebo 子集中的一部分 |
| | `gate` | 合并两个仿真器的分片、按仿真器分别打分、记录 MLflow、给模型打标签、决定是否晋级（见第 5 节） |
| `build-image.yaml` | `build` | kaniko 构建镜像并推到私有 ACR（`08-legged-sim2sim.sh image`） |

`gate` 通过扫描输入目录下的 `shard.json` 收集所有分片，不依赖 `{{input:N}}` 的编号（OSMO 在渲染 Jinja 之前会先替换 `{{input:N}}`，所以循环里无法拼出这种 token）。

## 5. 门禁规则

每个仿真器分别判定，**所有仿真器都通过**才算通过。只用**训练分布内**的场景判定（v2 包括组合扰动），分布外的场景只用于展示和诊断；Gazebo 中的无效回合（实时因子过低，或重试后仍启动失败）不参与统计：

- 摔倒率 ≤ 5%（`max_fall_rate`）
- 未摔倒回合的平均速度跟踪 RMSE ≤ 0.3 m/s（`max_lin_vel_rmse`）
- 转向跟踪 RMSE 只报告，不参与判定

`mode=promote`（`08-legged-sim2sim.sh validate`）：

- 挑战者没通过门禁 → 标签 `stage=rejected-gate`，工作流失败。
- 通过门禁，但在任一仿真器中摔倒率比冠军高 1 个百分点以上，或速度 RMSE 高 0.02 m/s 以上 → `stage=rejected-champion`，冠军不变。
- 否则晋级：挑战者 `stage=production`，原冠军 `stage=archived`。没有冠军时，通过门禁即晋级。

`mode=revalidate`（`08-legged-sim2sim.sh revalidate`）：对全部版本重新打分并更新标签，不做晋级；如果当前生产模型在新数据上不再通过门禁，工作流失败，提醒需要处理。

每个模型版本的标签：`sim2sim_validation=passed|failed`、`sim2sim_data_asset`、`sim2sim_simulators`、`sim2sim_<仿真器>_fall_rate`、`sim2sim_<仿真器>_lin_vel_rmse`、`sim2sim_fall_rate` / `sim2sim_lin_vel_rmse` / `sim2sim_ood_fall_rate`（各仿真器中最差的值）、`stage`。

## 6. 实测结果（2026-11-10）

被测模型：同一款点足机器人公开发布的两套预训练策略，`pointfoot-policy:1`（Isaac Gym 训练）和 `pointfoot-policy:2`（Isaac Lab 训练）。

> **适用范围**：以下数字来自本仓库的场景集、判定标准，以及 MuJoCo 一侧复现的部署控制循环（第 2 节），用来演示验证流程，不代表对这些策略的质量评价。门槛只是示例默认值。

### 6.1 平台层面：一次提交能得到什么

最后一次完整运行（`legged-validate-9`，2 个模型在场景集 v2 上重新验证，MuJoCo + Gazebo）：

| 项 | 结果 |
|---|---|
| 工作量 | MuJoCo 2,400 个回合（2 × 1,200）+ Gazebo 402 个回合（2 × 201，另有约 220 次启动重试） |
| 编排 | 1 个工作流、20 个任务：fetch → 10 个 MuJoCo 分片（1 CPU）+ 8 个 Gazebo 分片（2 CPU，私有 ACR 镜像）→ gate；超出 3 个 CPU 节点容量的分片由 OSMO 自动排队 |
| 时间 | 从提交到门禁结束约 75 分钟；串行估算约 5.5 小时（MuJoCo 约 80 分钟 + Gazebo 约 4 小时）。时间主要受 CPU 节点池上限（3 个节点）限制，调大 `cpu_node_max_count` 可以进一步缩短 |
| 记录 | AzureML 中每个模型、每个仿真器一个 MLflow 子运行（指标、逐回合结果、分维度图表），关联到数据资产版本和 OSMO 工作流 ID |
| 决策 | 门禁自动给模型版本打标签：v1 `sim2sim_validation=passed`、`stage=production`；v2 `failed`、`stage=rejected-gate` |
| 安全 | 全程 Workload Identity；数据湖、AzureML 存储、ACR 只走私网；不保存任何密钥或密码 |

### 6.2 演示过程

| 步骤 | 工作流 | 结果 |
|---|---|---|
| 发布场景集 v1、导入两套策略 | `legged-seed-2` | 数据资产 `pointfoot-sim2sim-scenarios:1`（1000 个场景）；模型 `pointfoot-policy:1`、`:2` |
| 验证 v1（还没有冠军，仅 MuJoCo） | `legged-validate-2` | 分布内摔倒 0.0%、速度 RMSE 0.241 m/s → 通过，晋级 `stage=production` |
| 验证 v2（挑战者 vs 冠军 v1，仅 MuJoCo） | `legged-validate-3` | 分布内摔倒 5.7%、速度 RMSE 0.330 m/s → 没达标，`stage=rejected-gate`，工作流失败；冠军保持不变 |
| 发布场景集 v2 | `legged-seed-3` | 数据资产 `pointfoot-sim2sim-scenarios:2`（1200 个场景，新增 200 个组合扰动） |
| 构建 Gazebo（ROS 2）镜像 | `build-image-1` | 约 3.5 分钟，推到私有 ACR |
| 全部版本在 v2 上、两个仿真器中重新验证 | `legged-validate-9` | 见下表 |

前三步在加入 2 s 热身（第 2 节）之前运行，加入热身后 MuJoCo 的数字只有小幅变化（例如 v2 在 v2 场景集上的分布内摔倒率从 17.5% 变为 18.0%）。

### 6.3 两个仿真器的对比（场景集 v2）

| 指标 | v1 MuJoCo | v1 Gazebo | v2 MuJoCo | v2 Gazebo |
|---|---|---|---|---|
| 场景数 | 1200 | 201 | 1200 | 201 |
| 分布内摔倒率（门禁 ≤ 5%） | 0.0% | 0.0% | **18.0%** | 0.0% |
| — 其中组合扰动 | 0.0% | 0.0% | 53.0% | 0.0% |
| 速度跟踪 RMSE（门禁 ≤ 0.3 m/s） | 0.244 | 0.169 | **0.328** | **0.320** |
| 转向跟踪 RMSE（rad/s，不门禁） | 0.171 | 0.173 | 0.022 | 0.041 |
| 分布外摔倒率：低摩擦 0.15–0.4 | 17% | 0% | 100% | 30% |
| 分布外摔倒率：推力 100–300 N | 21% | 4% | 39% | 37% |
| 分布外摔倒率：负载 +2–6 kg | 0% | 0% | 0% | 0% |
| 分布外摔倒率：延迟 20–60 ms | 32% | – | 83% | – |
| 无效回合（Gazebo 启动 5 次都失败） | – | 1 | – | 3 |
| 门禁 | 通过 | 通过 | 不通过 | 不通过 |

结论：

- **两个仿真器得出相同的晋级结论，但理由不同。** v2 在 MuJoCo 中主要是摔倒（组合扰动 53%），在 Gazebo（厂商自己的 ROS 2 部署栈）中不摔，但速度跟踪不达标。只用一个仿真器，看到的只是一面。
- **差异本身就是信息。** 例如 300 N 的侧推：MuJoCo 中两个策略都容易摔倒；Gazebo 中常常不倒，但会朝推力方向持续跑开。这类物理引擎之间的差异，正是上真机前需要知道的。
- 两套策略各有长处：v2 的转向跟踪明显好于 v1。分维度的结果可以帮助训练团队判断下一版该调整什么。
- 场景集升级后对所有版本重新验证，生产模型 v1 在新数据上仍然通过；数据版本和模型版本的对应关系都记录在 AzureML 里。

运行时间（CPU 节点池 D8s_v4，最多 3 个节点）：

| 工作流 | 回合数 | 每个分片 | 从提交到门禁结束 | 串行估算 |
|---|---|---|---|---|
| MuJoCo：1 个模型 × 1000 场景 | 1000 | 约 200 s | 约 11 分钟（其中约 4 分钟等节点池从 1 个扩到 3 个） | 约 35 分钟 |
| MuJoCo：2 个模型 × 1200 场景 | 2400 | 约 460 s | 约 19 分钟 | 约 80 分钟 |
| MuJoCo + Gazebo：2 个模型 × (1200 + 201) 场景 | 2802 | MuJoCo 约 460 s，Gazebo 约 30 分钟 | 约 75 分钟 | 约 5.5 小时 |

3 个节点同时只能放下约 9 个 CPU 分片（或 MuJoCo 和 Gazebo 分片的组合），其余分片排队，所以工作流的排队超时设为 2 小时。需要更快时，调大 Terraform 变量 `cpu_node_max_count`；正式环境可以给验证单独建一个 Spot CPU 节点池，按需扩到几十个节点。

## 7. 运行

前提：已完成 [AzureML 闭环](azureml-loop.md) 的资源部署，并按 `deploy/scripts/legged.env.example` 写好 `deploy/scripts/legged.env`。Gazebo 还需要私有 ACR（`infra/terraform/acr.tf`，`acr_enabled = true`），并重跑一次 `deploy/scripts/02-osmo-service.sh`：OSMO 提交时会检查镜像能否拉取，而私有 ACR 由 AKS 的 kubelet 身份拉取，OSMO 没有凭据，脚本会把 ACR 加入 `credential_config.disable_registry_validation`，不在 OSMO 中保存任何密码。

```bash
deploy/scripts/08-legged-sim2sim.sh image                       # 构建 Gazebo（ROS 2）镜像并推到 ACR
deploy/scripts/08-legged-sim2sim.sh seed import                 # 场景集 v1 + 导入策略（v1、v2）
MODELS=pointfoot-policy:1 deploy/scripts/08-legged-sim2sim.sh validate   # 无冠军，通过即晋级
MODELS=pointfoot-policy:2 deploy/scripts/08-legged-sim2sim.sh validate   # 挑战者 vs 冠军
PROFILE=v2 DATASET_VERSION=2 deploy/scripts/08-legged-sim2sim.sh seed    # 发布场景集 v2
deploy/scripts/08-legged-sim2sim.sh revalidate                  # 全部版本在最新场景集上重新验证
```

可调：`SHARDS`（MuJoCo 分片数，默认 10）、`GAZEBO_SHARDS`（默认 8，有 ACR 时生效；0 表示只跑 MuJoCo）、`LEGGED_SET="gazebo_subset_in=120 gazebo_subset_out=80"`（Gazebo 子集大小）、`DATASET`（`name` 或 `name:version`，默认最新版本）、`LEGGED_SET="max_fall_rate=0.1 max_lin_vel_rmse=0.35"`。

## 8. 在 AzureML Studio 中查看

- **Jobs → 实验 `pointfoot-sim2sim`**：`import-*` 运行保存模型文件；每次验证为每个模型、每个仿真器生成一个子运行 `sim2sim-pointfoot-policy-v<n>-<mujoco|gazebo>`，包含摔倒率、速度 / 转向 RMSE、按场景组的摔倒率（`fall_rate.in_dist.compound` 等）、Gazebo 的无效回合数和启动失败次数、逐回合 `episodes-*.csv`、分维度摔倒率图 `fall_rate_by_factor.png` 和 `breakdown.json`。
- **Models → `pointfoot-policy`**：按 `stage=production` 找到生产模型，按 `sim2sim_validation` 筛选，标签里能看到每个版本最近一次在哪个场景集版本上验证、结果如何。
- **Data → `pointfoot-sim2sim-scenarios`**：场景集的各个版本，标签里有各组场景数量。

和 AzureML 闭环一样，存储只走私网，从 VNet 外打开 Studio 时，指标、标签都能看，但预览产物文件会失败。
