#!/usr/bin/env bash
# 把 cmake --install 的产物整理成「终端可直接运行」的包
# 目标：adb shell / ZeroTermux 里 ./run.sh 就能跑，先验证 NPU 稳定性
#
# 用法: bash make_terminal_pkg.sh <pkg_dir> <out_dir> <v73|all>
set -euo pipefail

PKG_DIR="${1:?用法: make_terminal_pkg.sh <pkg_dir> <out_dir> <v73|all>}"
OUT_DIR="${2:?用法: make_terminal_pkg.sh <pkg_dir> <out_dir> <v73|all>}"
HTP_ARCH="${3:-all}"

LIB_DIR="${PKG_DIR}/lib"
BIN_DIR="${PKG_DIR}/bin"

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}/bin" "${OUT_DIR}/lib"

# ---- 1. 所有 .so 进 lib/ ----
cp -a "${LIB_DIR}"/*.so "${OUT_DIR}/lib/" 2>/dev/null || true

# ---- 2. 按架构过滤 HTP 固件库 ----
if [ "${HTP_ARCH}" = "v73" ]; then
  find "${OUT_DIR}/lib" -name 'libggml-htp-v*.so' ! -name 'libggml-htp-v73.so' -delete
fi

# ---- 3. 可执行文件进 bin/ ----
# 只收 ELF 可执行文件，跳过 .so / 非二进制
if [ -d "${BIN_DIR}" ]; then
  for f in "${BIN_DIR}"/*; do
    [ -f "${f}" ] || continue
    case "$(basename "${f}")" in
      *.so|*.dll|*.a|*.exe) continue ;;
    esac
    if head -c 4 "${f}" 2>/dev/null | grep -q $'\x7fELF'; then
      cp -a "${f}" "${OUT_DIR}/bin/"
      chmod +x "${OUT_DIR}/bin/$(basename "${f}")"
    fi
  done
fi

# ---- 4. 补 libc++_shared.so（没有它终端里直接 link 失败）----
if ! [ -f "${OUT_DIR}/lib/libc++_shared.so" ]; then
  NDK_ROOT="${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-}}"
  [ -z "${NDK_ROOT}" ] && NDK_ROOT="$(ls -d /opt/android-ndk-r* 2>/dev/null | head -1 || true)"
  CXX="$(find "${NDK_ROOT}" -path '*aarch64*' -name 'libc++_shared.so' 2>/dev/null | head -1 || true)"
  [ -z "${CXX}" ] && CXX="$(find "${NDK_ROOT}" -name 'libc++_shared.so' 2>/dev/null | head -1 || true)"
  if [ -n "${CXX}" ]; then
    cp -a "${CXX}" "${OUT_DIR}/lib/"
    echo "已补齐 libc++_shared.so"
  else
    echo "::warning::找不到 libc++_shared.so"
  fi
fi

# ---- 4.5 裁剪：只保留核心工具，并删掉没人引用的 .so ----
KEEP_TOOLS="${KEEP_TOOLS:-false}"
if [ "$KEEP_TOOLS" = "true" ]; then
  WANT="llama-cli llama-bench llama-quantize llama-perplexity llama-tokenize llama-gguf-hash"
  for f in "${OUT_DIR}"/bin/*; do
    [ -f "${f}" ] || continue
    n="$(basename "${f}")"
    keep=0
    for w in $WANT; do [ "$n" = "$w" ] && keep=1 && break; done
    [ "$keep" = "1" ] || rm -f "${f}"
  done
  echo "已裁剪工具，保留: $WANT"

  # 递归收集真正被引用的 .so，其余删除（系统库跳过）
  if command -v readelf >/dev/null 2>&1; then
    python3 - "$OUT_DIR" <<'PYX'
import os, subprocess, sys
out = sys.argv[1]
libd = os.path.join(out, 'lib')
bind = os.path.join(out, 'bin')
SYS = {'libc.so','libm.so','libdl.so','liblog.so','libandroid.so','libEGL.so',
       'libGLESv2.so','libOpenCL.so','libz.so','libstdc++.so','libpthread.so'}

def needed(p):
    try:
        r = subprocess.run(['readelf','-d',p], capture_output=True, text=True, timeout=60)
    except Exception:
        return []
    out_ = []
    for line in r.stdout.splitlines():
        if 'NEEDED' in line and '[' in line:
            out_.append(line.split('[',1)[1].rstrip(']').strip())
    return out_

# 这些是运行时 dlopen 的后端插件 / 必需运行时，readelf 扫不到依赖，必须强制保留
FORCE = set()
for f in sorted(os.listdir(libd)):
    if f.startswith('libggml-htp-') or f.startswith('libggml-') or f == 'libc++_shared.so':
        FORCE.add(f)
used |= FORCE

used = set(used)
frontier = []
for f in sorted(os.listdir(bind)):
    p = os.path.join(bind, f)
    if os.path.isfile(p):
        frontier.append(p)
for _ in range(4):
    nxt = []
    for p in frontier:
        for n in needed(p):
            if n in SYS or n in used:
                continue
            cand = os.path.join(libd, n)
            if os.path.isfile(cand):
                used.add(n)
                nxt.append(cand)
    frontier = nxt
    if not frontier:
        break

removed = 0
freed = 0
for f in sorted(os.listdir(libd)):
    if f.endswith('.so') and f not in used:
        p = os.path.join(libd, f)
        freed += os.path.getsize(p)
        os.remove(p)
        removed += 1
        print('  删除未引用: %s' % f)
print('裁剪 .so: %d 个，释放 %.1f MB' % (removed, freed/1048576))
print('保留 .so: %s' % ' '.join(sorted(used)))
PYX
  fi
fi

# ---- 5. 生成 run.sh：自动设好 LD_LIBRARY_PATH ----
cat > "${OUT_DIR}/run.sh" <<'EOS'
#!/system/bin/sh
# llama.cpp Hexagon HTP 终端运行入口
# 用法:
#   ./run.sh llama-cli -m model.gguf -p "你好" -n 128
#   ./run.sh llama-bench -m model.gguf
HERE="$(cd "$(dirname "$0")" && pwd)"
export LD_LIBRARY_PATH="$HERE/lib:$LD_LIBRARY_PATH"
export ADSP_LIBRARY_PATH="$HERE/lib"
export LD_PRELOAD="" 2>/dev/null || true

TOOL="${1:-llama-cli}"; shift || true
if [ ! -x "$HERE/bin/$TOOL" ]; then
  echo "可用工具: $(ls "$HERE/bin" | tr '\n' ' ')"
  exit 1
fi
exec "$HERE/bin/$TOOL" "$@"
EOS
chmod +x "${OUT_DIR}/run.sh"

# ---- 6. 生成一键自检脚本 ----
cat > "${OUT_DIR}/check-npu.sh" <<'EOS'
#!/system/bin/sh
# 快速自检：打印 SoC / HTP 架构探测 / 库加载情况
HERE="$(cd "$(dirname "$0")" && pwd)"
export LD_LIBRARY_PATH="$HERE/lib:$LD_LIBRARY_PATH"
export ADSP_LIBRARY_PATH="$HERE/lib"

echo "===== 设备 ====="
getprop ro.board.platform 2>/dev/null || true
getprop ro.chipname 2>/dev/null || true
getprop ro.soc.model 2>/dev/null || true
cat /proc/cpuinfo 2>/dev/null | grep -i -m1 'hardware' || true

echo
echo "===== 已带 HTP 固件库 ====="
ls -1 "$HERE/lib"/libggml-htp-v*.so 2>/dev/null || echo "(无)"

echo
echo "===== 依赖检查 ====="
for f in "$HERE"/bin/*; do
  [ -f "$f" ] || continue
  miss=0
  for need in $(readelf -d "$f" 2>/dev/null | grep -o 'NEEDED.*\[.*\]' | sed 's/.*\[//;s/\]//'); do
    if [ ! -e "$HERE/lib/$need" ]; then miss=1; echo "  缺: $need (被 $(basename "$f") 需要)"; fi
  done
done
echo "依赖检查完成"

echo
echo "===== 跑一次最小推理 ====="
echo "（如提示缺模型，请先 adb push 一个 .gguf 到这里）"
if ls "$HERE"/*.gguf >/dev/null 2>&1; then
  M="$(ls "$HERE"/*.gguf | head -1)"
  echo "使用模型: $M"
  exec "$HERE/run.sh" llama-cli -m "$M" -p "1+1=" -n 32 -ngl 99 -t 4
else
  echo "未找到 .gguf 模型，跳过推理测试"
fi
EOS
chmod +x "${OUT_DIR}/check-npu.sh"

# ---- 7. 去掉符号，减小体积 ----
if command -v llvm-strip >/dev/null 2>&1; then
  find "${OUT_DIR}/bin" -type f -exec llvm-strip --strip-unneeded {} \; 2>/dev/null || true
  find "${OUT_DIR}/lib" -name '*.so' -exec llvm-strip --strip-unneeded {} \; 2>/dev/null || true
fi

echo "=== bin ==="
ls -1 "${OUT_DIR}/bin" 2>/dev/null | head -30
echo "=== lib ==="
ls -1 "${OUT_DIR}/lib" 2>/dev/null | head -40
echo "=== 总大小 ==="
du -sh "${OUT_DIR}" 2>/dev/null || true
