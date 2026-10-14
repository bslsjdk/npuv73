#!/usr/bin/env bash
# 在电脑上执行：把 hexlab 推到手机并跑完整探测
#
#   bash run_on_device.sh [adb 序列号]
#
# 前置：out/ 下已经有 dsp/libhexprobe.so 和 arm/hexprobe_host

set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/out"
DEVICE="${1:-}"
ADB=(adb)
[ -n "$DEVICE" ] && ADB=(adb -s "$DEVICE")

DEST=/data/local/tmp/hexlab

if [ ! -f "$OUT/dsp/libhexprobe.so" ] || [ ! -f "$OUT/arm/hexprobe_host" ]; then
    echo "先跑 bash scripts/build.sh 生成 out/"
    exit 1
fi

echo "=== 推送 ==="
"${ADB[@]}" shell "mkdir -p $DEST/dsp $DEST/arm"
"${ADB[@]}" push "$OUT/dsp/libhexprobe.so" "$DEST/dsp/"
"${ADB[@]}" push "$OUT/arm/hexprobe_host" "$DEST/arm/"
"${ADB[@]}" push "$HERE/scripts/static_probe.sh" "$DEST/"
"${ADB[@]}" shell "chmod +x $DEST/arm/hexprobe_host $DEST/static_probe.sh"

echo
echo "=== 第 1 层：静态测绘 ==="
"${ADB[@]}" shell "cd $DEST && sh static_probe.sh" 2>&1 | tee "$OUT/static-$(date +%s).txt" | head -80

echo
echo "=== 第 2 层：DSP 微基准 ==="
"${ADB[@]}" shell "cd $DEST && \
    ADSP_LIBRARY_PATH=$DEST/dsp \
    LD_LIBRARY_PATH=$DEST/arm:/vendor/lib64:/system/lib64 \
    ./arm/hexprobe_host -o $DEST/result.csv" 2>&1 | tee "$OUT/bench-$(date +%s).txt"

echo
echo "=== 拉回结果 ==="
"${ADB[@]}" pull "$DEST/result.csv" "$OUT/result.csv" 2>/dev/null && echo "result.csv 已保存到 out/"

echo
echo "如果 skel 加载失败，常见原因："
echo "  1. ADSP_LIBRARY_PATH 没设对           -> 必须是放 libhexprobe.so 的目录"
echo "  2. 该机型禁用了 unsigned PD           -> 改试 adsp 域：把 dsp/ 目录也放进 /vendor/lib/rfsa/adsp"
echo "  3. 架构不匹配（v73 库跑在 v75 DSP）   -> bash scripts/build.sh v75 重编"
