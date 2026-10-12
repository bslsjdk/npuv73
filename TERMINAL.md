# 终端版：先在手机上跑通，再移植进 APK

这是**第一步**。目标很单纯：拿到一套能 `adb shell` / ZeroTermux 里直接执行的
llama.cpp，确认 Hexagon NPU 在你的 SM8635 上**跑得稳**，再谈塞进 Operit。

---

## 一、为什么先做终端版

APK 里出问题你什么都看不见：JNI 崩了、dlopen 失败了、DSP 挂了，全都只是
"应用闪退"。而终端里每条 FastRPC 报错、每个 backend 日志都会打在屏幕上。

先把下面这套跑通，你就知道：

- 你的 SoC 到底是 v73 还是 v75
- HTP 后端能不能正常 init
- 推理会不会中途 `AEE_EBADPARM`
- 实际 token 速度是多少

**这些确定了再动 APK，省得白折腾。**

---

## 二、怎么编

打开：

```
https://github.com/bslsjdk/npuv73/actions
```

左侧选 **Build llama.cpp 终端版 (adb / Termux 可直接跑)** → 右上 **Run workflow**：

| 参数 | 建议 | 说明 |
|---|---|---|
| `llama_ref` | `master` | 想锁版本填 tag |
| `htp_arch` | `all` | 四个架构全编；确定后改 `v73` 瘦身 |
| `build_type` | `release` | 调试选 `debug` |

跑完在页面底部 **Artifacts** 下载：

```
llama-hexagon-terminal-arm64
```

---

## 三、产物长什么样

```
out/
├── bin/
│   ├── llama-cli        ← 主命令行推理
│   ├── llama-bench      ← 跑分
│   ├── llama-server     ← 起个本地 HTTP 服务
│   ├── llama-quantize   ← 量化
│   └── ...
├── lib/
│   ├── libggml.so / libggml-base.so
│   ├── libggml-cpu.so
│   ├── libggml-opencl.so
│   ├── libggml-hexagon.so      ★ Hexagon 后端
│   ├── libggml-htp-v73.so      ★ v73 DSP 固件
│   ├── libggml-htp-v75.so
│   ├── libggml-htp-v79.so
│   ├── libggml-htp-v81.so
│   ├── libllama.so
│   └── libc++_shared.so
├── run.sh         ← 自动配好 LD_LIBRARY_PATH 的入口
└── check-npu.sh   ← 一键自检
```

---

## 四、在手机上跑（重点）

### 方式 A：adb shell（推荐，最干净）

```bash
# 电脑上
adb push out /data/local/tmp/llm
adb shell
```

```bash
# 手机里
cd /data/local/tmp/llm
chmod +x run.sh check-npu.sh bin/*
./check-npu.sh
```

`check-npu.sh` 会打印：

- SoC 型号（`ro.board.platform`）
- 带了哪些 HTP 固件库
- 有没有缺失的动态库依赖
- 有 gguf 就直接跑一次最小推理

### 方式 B：ZeroTermux

```bash
# Termux 里
cd /sdcard   # 或你放包的位置
cp -r /sdcard/download/out ~/llm
cd ~/llm
chmod +x run.sh bin/*
export LD_LIBRARY_PATH=$PWD/lib
./bin/llama-cli --help
```

> ZeroTermux 里 `run.sh` 用的是 `/system/bin/sh`，如果报
> `bad interpreter`，改成 `sh run.sh ...` 或直接手动 export 上面那行。

---

## 五、真机验证命令

先准备一个小模型（别一上来就 326MB 的）：

```bash
# 电脑上下载后推过去，或手机直接下
# 推荐 Qwen2.5-0.5B-Instruct Q4_0，约 350MB 以内、够小够快
adb push qwen2.5-0.5b-instruct-q4_0.gguf /data/local/tmp/llm/
```

然后：

```bash
cd /data/local/tmp/llm
./run.sh llama-cli \
  -m qwen2.5-0.5b-instruct-q4_0.gguf \
  -p "1+1等于几" \
  -n 64 -ngl 99 -t 4
```

**看这几件事：**

1. 启动日志里有没有 `ggml-hexagon` / `HTP` 字样 → 后端被加载了
2. 有没有 `libggml-htp-vXX.so` 加载成功 → 固件库匹配
3. 有没有再出现 `AEE_EBADPARM` → 说明还是没配对
4. 出 token 速度（`-ngl 99` 全 offload 到 NPU）

跑分：

```bash
./run.sh llama-bench -m qwen2.5-0.5b-instruct-q4_0.gguf -ngl 99
```

**稳定性压测**（这才是重点）：

```bash
# 连跑 20 次，看有没有随机崩
for i in $(seq 1 20); do
  echo "--- run $i ---"
  ./run.sh llama-cli -m qwen2.5-0.5b-instruct-q4_0.gguf \
    -p "讲个笑话" -n 128 -ngl 99 -t 4 2>&1 | tail -3
done
```

连续 20 次都能出结果、不出现 `AEE_*` 错误，才算稳。

---

## 六、确定 v73 还是 v75

`check-npu.sh` 会打 `ro.board.platform`。对照：

| 打印值 | SoC | HTP 架构 |
|---|---|---|
| `sm8550` / `kalama` | 8 Gen 2 | v73 |
| `sm8650` / `cliffs` | 8 Gen 3 | v75 |
| `sm8635` | 8s Gen 3 | **大概率 v75，需实测** |

判断方法：跑一次推理，看日志里实际加载的是哪个
`libggml-htp-vXX.so`。加载了哪个就是哪个。

确定之后把 `htp_arch` 改成对应值重跑一次，包能小几十 MB。

---

## 七、跑通之后再做 APK 版

终端版确认稳定了，再用同一个仓库的
**Build llama.cpp Hexagon HTP (Android arm64-v8a)** 工作流产出
`jniLibs/arm64-v8a/` 结构，往 Operit 里塞。那份工作流已经在仓库里了。

---

## 八、如果还是报 AEE_EBADPARM

按顺序排查：

1. **用 `all` 编的库**，让后端自己探测架构，别手动指定
2. 确认手机上没有其他旧版 `libggml-htp*.so`（`/vendor/lib64`、
   `/data/local/tmp` 里可能有你之前推的残留）→ 删掉
3. 确认 `libggml-hexagon.so` 和 `libggml-htp-vXX.so` 是**同一次编译**出来的
   （混用不同版本必崩，这就是你最初的病因）
4. 试试 `-ngl 0` 纯 CPU 跑通，确认模型本身没问题
5. 试 `debug` 构建，DSP 侧日志会更详细
