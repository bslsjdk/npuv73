# 模型选型：让 NPU 真正在干活

## 核心结论先说

**你的 `Ornith-1.5-9B-MTP-IQ4_XS.gguf` 在 Hexagon NPU 上几乎跑不出加速。**

不是库的问题，是**量化格式**的问题。

---

## 一、为什么 IQ4_XS 不行

Hexagon HTP 的加速靠 HVX（Hexagon Vector eXtensions）内核，这些内核是
手写汇编级别的，只对固定的几种数据布局有实现：

| 量化格式 | HTP / HVX | 说明 |
|---|---|---|
| **Q4_0** | ✅ 原生 | 最稳，HVX 有专门内核 |
| **Q4_K / Q4_K_M** | ✅ 支持 | 新版已实现 |
| **Q8_0** | ✅ 原生 | 常用于 KV cache |
| Q6_K | ✅ 支持 | 精度高、体积大 |
| **IQ4_XS** | ❌ 不支持 | i-matrix 非均匀量化，无 HVX 内核 |
| IQ2_XXS / IQ3_S / IQ4_NL | ❌ 不支持 | 同上 |

`IQ4_XS` 是重要性矩阵量化：每个 block 的缩放因子分布不规则，
HVX 的向量乘加单元没法直接处理，所以 **ggml 会自动把它回退到 CPU**。

结果就是：你 `-ngl 99` 全 offload，看起来模型加载了，
但**算力全在 CPU 上，NPU 闲着**，速度跟纯 CPU 没区别甚至更慢
（多了 FastRPC 拷贝开销）。

这正是你说的「CPU + NPU，NPU 跑 INT4」的关键 ——
**NPU 只认规则排布的 INT4（Q4_0 / Q4_K），不认 IQ 系列。**

---

## 二、你的模型还有两个额外麻烦

### 1. MoE 架构（1.5B 激活 / 9B 总参）

`1.5-9B` 说明这是 MoE：9B 总权重，每次推理只激活 1.5B。

问题：
- **9B 的权重全部要装进内存**，NPU 的 VTCM（8MB）装不下，
  实际是靠 DDR 共享 + 分块搬运
- MoE 的 router + 稀疏专家选择，HTP 后端支持不完整，
  很可能**整层回退 CPU**
- 手机内存压力：9B × 4bit ≈ 4.5GB 权重，加上 KV cache，
  8GB 内存的机器会很吃力

### 2. MTP（Multi-Token Prediction）

MTP 需要额外的 draft 头做投机解码。llama.cpp 里要单独跑
`llama-cli -m main.gguf -md draft.gguf`，HTP 后端对这块支持未知。

**建议先不管 MTP**，把它当普通模型测，跑通了再说。

---

## 三、正确做法：转成 Q4_K_M

### 方案 A：让 CI 帮你转（推荐，省手机算力）

如果你的模型能通过网络下载到（比如 HuggingFace 链接），
我可以在 npuv73 加一个 `requantize` 工作流，云端下好模型、
转成 Q4_K_M、再打包给你下载。

**你需要告诉我模型的下载直链**（HuggingFace 的 `resolve/main` 那种）。

### 方案 B：手机上自己转（包里已有 llama-quantize）

精简包里保留了 `llama-quantize`，可以直接在手机上跑：

```bash
cd /data/local/tmp/llm
export LD_LIBRARY_PATH=$PWD/lib:$LD_LIBRARY_PATH

# IQ4_XS -> Q4_K_M（会先反量化到 f32 再重量化，有精度损失但能上 NPU）
./bin/llama-quantize \
  Ornith-1.5-9B-MTP-IQ4_XS.gguf \
  Ornith-1.5-9B-Q4_K_M.gguf \
  Q4_K_M
```

> 9B 模型在手机上跑量化可能要十几分钟到半小时，
> 而且**需要额外 4~5GB 临时空间**（f32 中间态）。空间不够就别试。

### 方案 C：电脑上转（最快）

从 https://github.com/ggml-org/llama.cpp/releases 下
对应平台的 `llama-quantize`，在电脑上转完再推到手机。

---

## 四、验证 NPU 到底有没有在干活

转完之后这样测，重点看输出里的层分配：

```bash
./run.sh llama-cli \
  -m Ornith-1.5-9B-Q4_K_M.gguf \
  -p "1+1等于几" \
  -n 128 -ngl 99 -t 4 -v 2>&1 | tee run.log
```

然后看：

```bash
# 1. 有没有用上 NPU 后端
grep -iE 'hexagon|htp|ggml_backend' run.log | head -20

# 2. 有多少层 offload 了（关键！）
grep -iE 'offload|offloaded' run.log | head -10

# 3. 有没有大量回退 CPU 的警告
grep -icE 'fallback|not supported|CPU' run.log
```

**判据**：
- `offloaded X/Y layers` 里 X 接近 Y → NPU 吃下了大部分层 ✅
- 出现大量 `fallback to CPU` → 量化格式还是不对 ❌
- 速度对比：
  ```bash
  ./run.sh llama-bench -m model.gguf -ngl 0    # 纯 CPU 基线
  ./run.sh llama-bench -m model.gguf -ngl 99   # NPU 加速
  ```
  后者明显快（2x 以上）才算 NPU 真在干活。

---

## 五、如果 Q4_K_M 也不行，退到 Q4_0

Q4_0 是 HTP 支持最稳的，没有之一：

```bash
./bin/llama-quantize input.gguf output-q4_0.gguf Q4_0
```

代价：Q4_0 比 Q4_K_M 精度差一点（per-block 单一缩放因子），
但**兼容性最好**。先确认 NPU 能加速，再考虑精度取舍。

---

## 六、模型大小建议

你这块 SM8635 + 8s Gen 3，实用上限大概是：

| 参数量 | Q4_K_M 体积 | 可行性 |
|---|---|---|
| 0.5B | ~350MB | ✅ 很流畅，建议先用它验证 |
| 1.5B | ~1GB | ✅ 可用 |
| 3B | ~2GB | ⚠️ 勉强 |
| 7~9B | ~4.5GB | ❌ 大概率 OOM / 极慢 |

**强烈建议先拿 Qwen2.5-0.5B-Instruct 的 Q4_0 测**：
体积小、速度可控、能快速确认 NPU 链路通不通。
9B 那个等链路确认了再上。

---

## 七、一句话总结

> NPU 只吃 **Q4_0 / Q4_K_M** 这种规则 INT4；
> `IQ4_XS` 会被静默回退到 CPU，白忙一场。
> 先转成 Q4_K_M，用 `-ngl 99` + `-v` 看 offload 层数，
> 拿 `llama-bench -ngl 0` vs `-ngl 99` 对比速度，
> 有明显提升才算 NPU 真在工作。
