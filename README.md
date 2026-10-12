# npuv73 — 骁龙 8s Gen 3 (SM8635) Hexagon NPU 后端云端编译

用 GitHub Actions + 高通官方工具链容器，把 llama.cpp 的 **Hexagon HTP 后端**
编译成 Android 能直接用的 `.so`，最终塞进 `jniLibs/arm64-v8a/` 打包进 APK。

---

## 一、为什么你之前会报那个错

```
HTP0 buffer mapping failed : domain_id 3 size 69632 fd 23
error 0x0000000e (AEE_EBADPARM)
```

`AEE_EBADPARM` = 传给 DSP 的参数不合法。你那套是"旧版 `libggml-htp-v73.so`
重命名成 `libhtp_iface.so` 顶符号"拼出来的，**ARM 侧调度库和 DSP 侧固件的
ABI/版本对不上**，DSP 拿到的 buffer 描述就是错的。

正确做法：让 llama.cpp 的构建系统**自己**编译出 HTP 固件库。官方 CMake 里有
`htp-v73` 这个构建目标，它会用 `hexagon-clang` 从源码生成 v73 的 DSP kernel，
再用 `qaic` 生成 stub/skel，最后产出的 `libggml-htp-v73.so` 和
`libggml-hexagon.so` 天生是配套的。本仓库就是干这件事的。

---

## 二、它怎么绕开"Hexagon SDK 要高通账号"这个坑

高通的 Hexagon SDK 确实要登录开发者账号才能下载，GitHub Actions 没法自动拿。
但高通官方在 GitHub 上公开了带完整工具链的容器镜像：

```
ghcr.io/snapdragon-toolchain/arm64-android:v0.7
```

里面已经预装好：

| 组件 | 版本 |
|---|---|
| Android NDK | r28b |
| Hexagon SDK | 6.6.0.0 |
| OpenCL SDK | 2.x |
| CMake / hexagon-clang | 配套版本 |

llama.cpp 官方自己的 CI（`.github/workflows/build-and-test-snapdragon.yml`）
就是直接 `container: image: ghcr.io/snapdragon-toolchain/arm64-android:v0.7`
跑的。本仓库照抄了这个思路，所以**你什么都不用装**。

---

## 三、操作步骤（照着点就行）

### 第 1 步：确认文件已就位

仓库里应该有这两个文件：

```
.github/workflows/build-htp-android.yml
scripts/make_jniLibs.sh
```

### 第 2 步：打开 Actions 页面

浏览器打开（手机建议先切「桌面版网站」）：

```
https://github.com/bslsjdk/npuv73/actions
```

### 第 3 步：手动触发构建

1. 左侧工作流列表点 **Build llama.cpp Hexagon HTP (Android arm64-v8a)**
2. 右上角点 **Run workflow** 下拉按钮
3. 参数保持默认即可：

   | 参数 | 默认 | 说明 |
   |---|---|---|
   | `llama_ref` | `master` | 想锁版本就填 tag，如 `b6789` |
   | `htp_arch` | `all` | 全部编 v73/v75/v79/v81；只想要 v73 就选 `v73` |
   | `build_type` | `release` | 调试时选 `debug` |

4. 点绿色 **Run workflow**

### 第 4 步：等

首次运行要拉一个 10GB+ 的工具链镜像，可能要 20–40 分钟。
之后编译本身约 15–30 分钟。页面变绿勾就是成功。

### 第 5 步：下载产物

构建完成后，点进那次运行记录，页面最下方 **Artifacts** 区域：

```
llama-hexagon-android-arm64   ← 点它下载 zip
```

解压后结构：

```
out/
├── jniLibs/arm64-v8a/
│   ├── libggml.so              或 libggml-base.so
│   ├── libggml-cpu.so          CPU 后端
│   ├── libggml-opencl.so       Adreno GPU 后端
│   ├── libggml-hexagon.so      ★ Hexagon 后端（ARM 侧调度）
│   ├── libggml-htp-v73.so      ★ v73 DSP 固件（8 Gen 2 / 8s Gen 3）
│   ├── libggml-htp-v75.so      v75 DSP 固件（8 Gen 3）
│   ├── libggml-htp-v79.so      v79（8 Elite）
│   ├── libggml-htp-v81.so      v81
│   ├── libllama.so             llama.cpp 主库
│   └── libc++_shared.so        NDK 运行时（脚本自动补齐）
├── include/                    头文件
└── bin/                        llama-cli / llama-bench（adb 验证用）
```

---

## 四、关于 SM8635 该用 v73 还是 v75

高通的 HTP 架构对应关系大致是：

| SoC | HTP 架构 | 机型 |
|---|---|---|
| SM8550 | v73 | 骁龙 8 Gen 2 |
| SM8650 | v75 | 骁龙 8 Gen 3 |
| SM8750 | v79 | 骁龙 8 Elite |

SM8635（8s Gen 3）是 8 Gen 3 的衍生版，**大概率是 v75**，但你手上既然
已经有能跑的 v73 库，说明也可能是 v73。

所以默认参数选 `all` —— 反正一次全编出来，四个架构库都给你。真机上
`libggml-hexagon.so` 会在运行时自动探测 SoC 并加载匹配的那个，装全套不会
冲突，只是 APK 大几十 MB。确定之后再把 `htp_arch` 改成 `v73` 重跑一次瘦身。

---

## 五、集成进 Operit AI（关键，别跳过）

**⚠️ 这里有个坑**：Operit 的 `llm/llama` 模块里有一份自己的 JNI 桥接层
（`llama_jni_stub.cpp`，符号形如 `Java_com_ai_assistance_llama_LlamaNative_*`），
官方编译出来的 `libllama.so` **不包含这些符号**。

所以分两种情况：

**A. 只想让 Hexagon NPU 后端能被加载**

把这几个库放进 Operit 的 `app/src/main/jniLibs/arm64-v8a/`：

```
libggml.so / libggml-base.so
libggml-cpu.so
libggml-hexagon.so
libggml-htp-v73.so（及其他架构）
libc++_shared.so
```

`libggml-hexagon.so` 是作为 ggml 后端插件被 `dlopen` 的， Operit 那套
`libllama.so` 只要链接的 ggml 版本接近就能加载它。

**B. 想整体升级 llama.cpp（更彻底）**

用本仓库产出的 `lib/*.so` + `include/*.h` 替换 Operit `llm/llama` 模块里
的预编译依赖，然后让该模块的 CMake 重新编译它的 JNI stub 去链接新的
`libllama.so`。这条路需要对齐 ggml 头文件版本，改动更大。

建议先用 **A** 验证 NPU 能不能跑通，再考虑 B。

**验证方式**（adb）：

```bash
adb push out/bin/llama-cli out/jniLibs /data/local/tmp/llm/
adb shell "cd /data/local/tmp/llm && \
  LD_LIBRARY_PATH=. ./bin/llama-cli -m model.gguf -p 'hi' -ngl 99"
```

看到后端日志里出现 Hexagon / HTP 且能出 token，就说明库没问题，
再往 APK 里塞。

---

## 六、费用提醒

仓库是 **private**，GitHub 免费额度是每月 2000 分钟，私有仓库按 2 倍
计费（Linux runner）。一次完整构建约 40–60 分钟 ≈ 消耗 80–120 分钟额度，
一个月跑十几次没问题。别重复触发就行（工作流已加 `cancel-in-progress`）。
