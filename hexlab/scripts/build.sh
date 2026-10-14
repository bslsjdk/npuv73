#!/usr/bin/env bash
# hexlab 构建脚本
#
# 产出两套二进制，同名不同架构（FastRPC 的惯例）：
#   dsp/libhexprobe.so   —— hexagon-clang 编译，跑在 cDSP 上（skel）
#   arm/hexprobe_host    —— NDK clang 编译，跑在 ARM 上（调用方）
#
# 用法: bash build.sh [v73|v75|v79|v81]
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${1:-v73}"
OUT="$HERE/out"
mkdir -p "$OUT/dsp" "$OUT/arm" "$OUT/gen"

echo "########## 工具链探测 ##########"

HEX_CLANG=""
for c in hexagon-clang /opt/qcom/hexagon/bin/hexagon-clang /usr/bin/hexagon-clang; do
    if command -v "$c" >/dev/null 2>&1; then HEX_CLANG="$(command -v "$c")"; break; fi
done
if [ -z "$HEX_CLANG" ]; then
    HEX_CLANG="$(find / -name 'hexagon-clang' -type f 2>/dev/null | head -1 || true)"
fi
echo "hexagon-clang : ${HEX_CLANG:-未找到}"

QAIC=""
if command -v qaic >/dev/null 2>&1; then
    QAIC="$(command -v qaic)"
else
    QAIC="$(find / -name 'qaic' -type f 2>/dev/null | head -1 || true)"
fi
echo "qaic          : ${QAIC:-未找到}"

# Hexagon SDK 头文件（qurt.h / hexagon_types.h / hexagon_protos.h）
HEX_INC=""
for p in /opt/qcom/Hexagon_SDK /opt/hexagon_sdk /opt/Hexagon_SDK /hexagon_sdk; do
    if [ -d "$p" ]; then
        HEX_INC="$p"
        break
    fi
done
if [ -z "$HEX_INC" ]; then
    HEX_INC="$(find / -maxdepth 4 -type d -name 'Hexagon_SDK*' 2>/dev/null | head -1 || true)"
fi
echo "Hexagon SDK   : ${HEX_INC:-未找到}"

if [ -n "$HEX_CLANG" ]; then "$HEX_CLANG" --version 2>&1 | head -3 || true; fi

echo
echo "########## 生成 stub / skel ##########"
if [ -z "$QAIC" ]; then
    echo "::error:: 找不到 qaic，无法生成 FastRPC stub/skel"
    exit 1
fi
"$QAIC" -mdll -o "$OUT/gen" "$HERE/idl/hexprobe.idl" 2>&1 | head -20 || true
ls -la "$OUT/gen"
if [ ! -f "$OUT/gen/hexprobe.h" ]; then
    echo "::error:: qaic 没有生成 hexprobe.h"
    exit 1
fi

echo
echo "########## 编译 DSP 侧 ($ARCH) ##########"
if [ -z "$HEX_CLANG" ]; then
    echo "::error:: 找不到 hexagon-clang"
    exit 1
fi

INC_FLAGS=()
if [ -n "$HEX_INC" ]; then
    for d in "$HEX_INC"/incs "$HEX_INC"/incs/stddef "$HEX_INC"/rtos/qurt/computev66/include/qurt \
             "$HEX_INC"/rtos/qurt/computev68/include/qurt "$HEX_INC"/libs/common/rpcmem; do
        [ -d "$d" ] && INC_FLAGS+=("-I$d")
    done
fi

set +e
# shellcheck disable=SC2086
"$HEX_CLANG" -m"$ARCH" -O3 -fPIC -shared \
    "${INC_FLAGS[@]}" \
    -I"$OUT/gen" -I"$HERE/dsp" \
    -o "$OUT/dsp/libhexprobe.so" \
    "$OUT/gen/hexprobe_skel.c" \
    "$HERE/dsp/hexprobe_skel.c" 2>&1 | tee "$OUT/dsp-build.log" | head -60
DSP_RC=${PIPESTATUS[0]}
set -e
if [ "$DSP_RC" != "0" ]; then
    echo "::error:: DSP 编译失败，完整日志见 out/dsp-build.log"
    echo "如果报错指向 Q6_Vuw_vrmpy_VubVub，重跑时加 -DHP_HAVE_VRMPY=0"
    exit 1
fi
echo "DSP 编译成功"

echo
echo "########## 编译 ARM 侧 ##########"
CC="${CC:-}"
if [ -z "$CC" ]; then
    for c in clang aarch64-linux-android26-clang aarch64-linux-android34-clang gcc; do
        if command -v "$c" >/dev/null 2>&1; then CC="$(command -v "$c")"; break; fi
    done
fi
echo "ARM 编译器    : ${CC:-未找到}"
if [ -z "$CC" ]; then
    echo "::error:: 找不到 ARM 编译器"
    exit 1
fi

set +e
"$CC" -O2 -fPIC -I"$OUT/gen" -I"$HERE/arm" \
    -o "$OUT/arm/hexprobe_host" \
    "$HERE/arm/hexprobe_host.c" \
    "$OUT/gen/hexprobe_stub.c" \
    -ldl 2>&1 | tee "$OUT/arm-build.log" | head -40
ARM_RC=${PIPESTATUS[0]}
set -e
if [ "$ARM_RC" != "0" ]; then
    echo "::error:: ARM 编译失败，日志见 out/arm-build.log"
    exit 1
fi
echo "ARM 编译成功"

echo
echo "########## 产出 ##########"
ls -la "$OUT/dsp" "$OUT/arm"
