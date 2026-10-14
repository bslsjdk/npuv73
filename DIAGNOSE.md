# NPU 落地诊断：别猜，直接看数据

`diag-npu.sh` 会打开 `GGML_HEXAGON_VERBOSE`，把 ggml-hexagon 内部
**每一个 op 的 supports-op 判定**抓下来，然后统计到底多少上了 NPU、
多少回退 CPU、被拒的都是什么类型。

---

## 一、用法

```bash
adb push out /data/local/tmp/llm
adb shell
cd /data/local/tmp/llm
chmod +x diag-npu.sh bin/*

# 全员 offload
./diag-npu.sh model.gguf 99 32

# CPU 基线（同一模型，关掉 offload）
./diag-npu.sh model.gguf 0 32
```

参数：`./diag-npu.sh <模型> [ngl] [生成token数]`

日志落在同目录 `diag-<时间戳>.log`。

---

## 二、输出怎么看

脚本分 6 段：

| 段 | 内容 | 关注点 |
|---|---|---|
| [1] | 设备信息 | `ro.board.platform` 确认 SoC |
| [2] | HTP 架构探测 | 包里带了哪些 vXX 固件 |
| [3] | 推理结果 | 退出码、耗时 |
| [4] | **supports-op 统计** | yes/no 数量与覆盖率 |
| [5] | **被拒的算子** | 去重列出，看是什么类型 |
| [6] | 后端、offload、速度 | 实际 token 速度 |

**最关键的是 [4] 和 [5]。**

---

## 三、判据

### 覆盖率 > 80% → NPU 链路通了

`supports-op ... |yes` 占绝大多数，说明量化格式和形状都被 HTP 接受。
接下来看 [6] 的速度对比 `-ngl 0`，有 2x 以上提升就算成功。

### 覆盖率 < 30% → 格式不对

大概率 [5] 里会出现大量同一类型的层被拒。常见：

- 全是 `IQ4_XS` → 就是你现在的模型，转 Q4_K_M
- 全是 `F32` / `F16` 权重 → 模型本身没量化
- 报 `GGML_PREC_F32` 相关 → MoE 的 mul_mat_id 走了 f32 精度分支

### 覆盖率 0 且没有 supports-op 输出

说明 verbose 没生效，或根本没加载 Hexagon 后端。检查：

```bash
ls lib/libggml-hexagon.so          # 在不在
export GGML_HEXAGON_VERBOSE=1
./bin/llama-cli --version          # 看后端列表
```

---

## 四、[6] 里的速度怎么看

`llama-cli` 会打 `eval time`，换算成 t/s。跑两次对比：

```bash
./diag-npu.sh model.gguf 0 32    # CPU 基线
./diag-npu.sh model.gguf 99 32   # NPU
```

**后者快 2x 以上**才算 NPU 真在干活。如果 `-ngl 99` 反而更慢，
说明权重在 CPU 和 DSP 之间来回搬运，开销盖过了加速——这时该减少
offload 层数（比如 `-ngl 20`）而不是全 offload。

---

## 五、已知会回退的情况

从源码看，`supports_op` 在以下情况返回 false：

| 条件 | 位置 | 说明 |
|---|---|---|
| `dst->type != F32` | ggml-hexagon.cpp:7028 | 输出必须是 f32 |
| `src0` 非 repack 类型 | :7036 | 见白名单 |
| `src0` 不连续 / 被 permute | :7047 | 布局要求 |
| `ne[0]` 不对齐 32 或 QK_K | :7051 | K 系列要 256 对齐 |
| MoE 走 `GGML_PREC_F32` | :7119 | mul_mat_id 的精度分支 |

回退是 **per-op** 的，不是整模型。所以 Q4_K_M 里 Q4_K 上 NPU、
个别 op 落 CPU 属于正常。

---

## 六、拿到数据之后

把下面几段贴给我：

1. `[4/6] 算子支持统计` 的 yes/no/覆盖率
2. `[5/6] 被拒的算子` 全部条目
3. 两次 `[6/6]` 的 token 速度

我据此判断下一步是转格式、调 offload 层数，还是真需要补内核。
