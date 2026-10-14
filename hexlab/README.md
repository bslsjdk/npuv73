# hexlab — 自研 Hexagon NPU 计算引擎

目标不是给 llama.cpp 打补丁，而是**把 SM8635 里的 Hexagon 当成独立计算平台**，
从硬件接口到神经网络内核逐层研究、逐层自建，每一步都有实测数字。

现成的 llama.cpp / Hexagon SDK 只是**参考与对照组**，不是地基。

---

## 硬性约束

| 项 | 值 |
|---|---|
| 目标设备 | RMX3852 / Snapdragon 8s Gen 3 / SM8635 |
| 运行方式 | 手机离线，不依赖云端 |
| 运行时 RAM | **≤ 4 GB**（记录峰值，不看模型文件大小） |
| 计算重点 | **真正的 INT4 执行效率** |
| 验收 | 正确性（对 CPU 参考）、速度（微内核 + 端到端）、内存峰值、可复现 |

---

## 六层结构

```
第 6 层  AI 推理引擎     Transformer / MoE / 注意力 / KV Cache / 算子调度
第 5 层  INT4 量化计算    打包权重、解码、缩放、累加、混合精度
第 4 层  自研计算内核     向量点积、矩阵乘法、激活函数、归约
第 3 层  内存与执行调度   DMA、缓冲区、同步、流水线、并行执行
第 2 层  硬件执行接口     FastRPC、cDSP 域、驱动与运行时
第 1 层  硬件能力测绘     指令、存储层级、带宽、延迟、功耗
```

**当前进度：第 1 层 + 第 2 层起步。**

---

## 必须先分清的概念

Hexagon DSP、HTP 加速器、手机营销意义上的 "NPU" **不是一回事**：

- **cDSP** — 一个可编程的 VLIW 处理器，能加载我们自己编译的 .so
- **HVX** — cDSP 上的宽向量单元（128 字节向量寄存器）
- **HMX** — 部分新架构上的矩阵乘协处理器
- **HTP** — 高通对这套东西的包装名词

看到一个 `libQnnHtp.so` 不等于拥有底层能力。每一项能力都要**实测证据**。

---

## 这次交付了什么

### 第 1 层（不进 DSP，今天就能跑）

`scripts/static_probe.sh` — 纯读系统信息：

- SoC / 板级标识、CPU 集群与频率
- DSP 设备节点：`/dev/cdsprpc-smd`、`remoteproc` 固件与状态、子系统重启计数
- 厂商库清点：`libcdsprpc.so`、`libQnnHtp*`、各 NPU 栈
- GPU 型号与频率（第二回退路径）
- 内存总量、CMA、DMA-BUF heaps
- 温控区（决定长时间能不能跑满）

```bash
adb push scripts/static_probe.sh /data/local/tmp/
adb shell "sh /data/local/tmp/static_probe.sh" > static.txt
```

### 第 2 层（我们自己的 DSP 程序）

关键在于：**FastRPC 允许加载未签名的 DSP .so**（llama.cpp 的
`libggml-htp-v73.so` 就是这么进去的）。所以我们能在 cDSP 上跑**自己写的代码**。

| 文件 | 作用 |
|---|---|
| `idl/hexprobe.idl` | 我们自己的 FastRPC 接口（不是 llama.cpp 的 htp_iface） |
| `dsp/hexprobe_skel.c` | DSP 侧实现，用 HVX 内联 + 周期计数器 `C15:14` |
| `arm/hexprobe_host.c` | ARM 侧宿主，dlopen `libcdsprpc.so`，墙钟计时 |
| `scripts/build.sh` | 用 `hexagon-clang` + `qaic` 构建两侧二进制 |

URI 格式（从 llama.cpp 源码确认）：
```
file:///libhexprobe.so?hexprobe_skel_handle_invoke&_modver=1.0
```

---

## 微基准清单

`which` 参数 |

| which | 测试 | 要回答的问题 |
|---|---|---|
| 1 | 空调用 | FastRPC 往返本身多少开销 |
| 2 | INT8 向量加 | byte lane 的实际吞吐 |
| 3 | INT16 乘加 | halfword lane 是否可用 |
| 4 | **INT4 打包点积** | 能否消费打包权重，还是必须先解包 |
| 5 | memcpy | DSP 视角的 DDR 带宽 |
| 6 | INT8 GEMM | 不同 K 下的吞吐量变化 |
| 7 | **INT4 GEMM** | 解包+点积能否融合 |

外加 `spin()`：DSP 空转固定周期，ARM 侧计时 → **实测 MHz**。
短时间跑 vs 长时间跑对比，直接看出降频。

输出 CSV：`name, which, len, iters, cycles, ops, usec, mhz, chk, cycles_per_op, gops`

---

## 怎么跑

```bash
# 1. 云端构建（GitHub Actions，已配好高通工具链容器）
#    Actions → hexlab — 自研 Hexagon 探测 → Run workflow
#    下载 artifact: hexlab-v73

# 2. 推到手机跑
bash scripts/run_on_device.sh
```

---

## 关于 INT4 的三个层次

这点必须说清楚，否则会自欺欺人：

1. **INT4 存储** — 权重以 4-bit 存，省内存和带宽。容易做到。
2. **INT4 运算** — 算术在 4-bit 域完成。取决于硬件有没有对应指令。
3. **INT4 全流程高效** — 从 DDR 到结果，中间不解包、不落地、不重复搬。

即使硬件只能以某种内部格式执行，我们仍可优化布局与流水线。
**但能不能做到真正的 4-bit 原生计算，必须由硬件证据决定，不能靠推断。**

---

## 验收标准（写进每次提交）

- **正确性**：每个内核对 CPU 参考实现，记录误差与长序列稳定性
- **速度**：同时测微内核与端到端，**不拿单内核峰值冒充生成速度**
- **内存**：记录运行时峰值 RAM，硬上限 4 GB
- **可复现**：保留基线、测试数据、设备状态（温度/电量/频率）

没有实测结果，就不宣布某种算法更快。
