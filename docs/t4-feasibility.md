# T4（Standard_NC*as_T4_v3）运行仿真作业的可行性评估

> 评估时间：2026-11-05。以下结论来自公开文档和社区信息，**还没有在真实 T4 机器上实测**。
> T4 的规格：Turing 架构（compute capability 7.5），16 GB 显存，有 RT Core。

## 结论汇总

| 负载 | 结论 | 可信度 |
|---|---|---|
| OSMO 主链路（调度、GPU 作业、`nvidia-smi`） | ✅ 可行 | 高：GPU Operator 官方支持 T4 和 AKS |
| Isaac Lab 3.0，默认的 Newton 后端，headless 训练（不用相机渲染） | ✅ 可行 | 高：官方要求“Turing 及以上（CC 7.5+）”，T4 刚好达到下限，且“headless Newton 不需要 RTX 硬件” |
| Isaac Lab 加 Isaac Sim 6.x（PhysX 或 RTX 渲染、相机传感器） | ⚠️ 不确定，可能能跑但性能差 | 低：T4 不在官方 GPU 列表里，社区有在 T4 上 Vulkan 初始化失败的报告 |
| MuJoCo（CPU 物理） | ✅ 可行，基本不依赖 GPU | 高 |
| MuJoCo MJX / MuJoCo Warp（GPU 并行） | ✅ 大概率可行 | 中：JAX、Warp 支持 CC 7.5 |
| Gazebo（物理在 CPU 上算，传感器渲染用 OpenGL/EGL） | ✅ 可行 | 中：headless 渲染需要容器内有 EGL/图形能力 |

## 依据

### Isaac Lab 3.0（当前 main 文档）
- 默认安装的是 Newton 后端，**不需要 Isaac Sim**。原文是 “Headless Newton simulation does not require RTX hardware”。
- GPU 要求是 “The default CUDA 13 stack requires Turing or newer (compute capability 7.5+)”。**T4 刚好满足。**
- **驱动要求 Linux x86_64 `595.58.03`**，这个下限是 PyTorch CUDA 13 定的。AKS 自动安装的驱动版本可能达不到，所以需要用 GPU Operator 安装 595 分支的驱动。
- 加装 Isaac Sim 的部分要求“至少 32 GB RAM、16 GB VRAM，以及受支持的 RTX GPU”。

### Isaac Sim 6.x 官方要求
- 最低配置 RTX 4080 / 16 GB 显存 / 32 GB 内存，测试驱动版本是 595.58.03。
- 原文是 “GPUs without RT Cores (A100, H100) are not supported”。T4 有 RT Core，没有被排除，但也**没有出现在支持列表里**。
- Isaac Sim 5.1 的 GCP、阿里云、腾讯云部署指南里用过 T4 机型做示例，说明官方以前用 T4 跑过。

### 社区反馈
- NVIDIA 论坛有人（Isaac Sim 5.0、驱动 580）在 GCP T4 上遇到 `vkCreateInstance failed / ERROR_INCOMPATIBLE_DRIVER`，没有解决。回复的人认为 T4“技术上可以跑，但因为图形和 RTX 性能较低，官方不推荐”，建议换 L40 或 A6000。
- 论坛版主认为 T4 和 A10 都具备 RTX 能力，但这不是官方的支持承诺。

### GPU Operator
- v26.7 官方支持 **T4** 和 **AKS**（Ubuntu 22.04 / 24.04，K8s 1.33–1.37）。默认驱动是 **595.91.07**，正好满足 Isaac Lab 3.0 的驱动要求。

## 对 PoC 的影响和建议

1. **GPU 节点池设置 `gpu_driver = None`**，由 GPU Operator 安装 595 分支的驱动，不用 AKS 自带的驱动。这样同时满足 OSMO 的 GPU 验证和 Isaac Lab 3.0 的要求。
2. **Isaac 示例作业选 Isaac Lab 3.0 加 Newton 做 headless 训练**，比如 Cartpole 或 Ant 这类小任务，并控制并行环境数量。这条路径在 T4 上有官方依据。
3. **Isaac Sim 渲染和相机类作业列为第一阶段的“探索项”，不算成功标准**：
   - 如果出现 Vulkan 相关报错，先检查容器的 `NVIDIA_DRIVER_CAPABILITIES` 是否包含 `graphics`（或设为 `all`），以及驱动是否带 Vulkan ICD。
   - 跑不起来就作为结论记录下来：“渲染类作业需要 A10、L4 或 L40S 级别的 GPU”。
4. **节点规格**：Isaac 类作业用 NC8as_T4_v3（8 核 / 56 GB）或 NC16as_T4_v3（16 核 / 110 GB）。NC4as 的 28 GB 内存不够 Isaac Sim 的 32 GB 下限。
5. **拿到 T4 机器后的实测清单**：
   - [ ] `nvidia-smi` 显示的驱动版本是 595.x
   - [ ] Isaac Lab 3.0 Newton headless 训练（Cartpole）能跑通
   - [ ] Isaac Sim 6.x headless 启动，确认 Vulkan 能正常初始化
   - [ ] MuJoCo 和 Gazebo 示例作业能跑通

## 参考链接
- Isaac Sim 系统要求：https://docs.isaacsim.omniverse.nvidia.com/latest/installation/requirements.html
- Isaac Lab 安装与要求：https://isaac-sim.github.io/IsaacLab/main/source/isaaclab/installation.html
- GPU Operator 平台支持：https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/platform-support.html
- Isaac Sim 5.1 GCP 部署（使用 T4 机型）：https://docs.isaacsim.omniverse.nvidia.com/5.1.0/installation/install_advanced_cloud_setup_gcp.html
- 论坛：在 Brev（GCP）T4 上启动 Isaac Sim 出错：https://forums.developer.nvidia.com/t/error-launching-isaac-sim-on-nvidia-brev-platform-t4-gpu-gcp/347555
- 论坛：T4 云 GPU 的 RTX 能力：https://forums.developer.nvidia.com/t/issac-sim-rtx-requirements-for-t4-cloud-gpu-and-omniverse-streaming-client/323564
