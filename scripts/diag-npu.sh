#!/system/bin/sh
# ================================================================
# NPU 落地诊断：到底哪些算子/层真的跑在 Hexagon 上
#
# 用法:
#   ./diag-npu.sh <模型.gguf> [ngl] [n]
#   ./diag-npu.sh model.gguf 99 32
#   ./diag-npu.sh model.gguf 0 32     # CPU 基线对比
# ================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MODEL="${1:?用法: diag-npu.sh <模型.gguf> [ngl] [n]}"
NGL="${2:-99}"
N="${3:-32}"
LOG="$HERE/diag-$(date +%s).log"

export LD_LIBRARY_PATH="$HERE/lib:$LD_LIBRARY_PATH"
export ADSP_LIBRARY_PATH="$HERE/lib"
export GGML_HEXAGON_VERBOSE=1

if [ ! -f "$MODEL" ]; then
  echo "找不到模型: $MODEL"
  echo "当前目录的 gguf:"; ls -1 "$HERE"/*.gguf 2>/dev/null || echo "  (无)"
  exit 1
fi

echo "=========================================="
echo " 模型: $(basename "$MODEL")"
echo " ngl=$NGL  n=$N"
echo " 日志: $LOG"
echo "=========================================="

# ---------- 1. 设备信息 ----------
echo
echo "[1/6] 设备信息"
for p in ro.board.platform ro.chipname ro.soc.model ro.product.board \
         ro.hardware ro.soc.manufacturer; do
  v="$(getprop "$p" 2>/dev/null)"
  [ -n "$v" ] && echo "  $p = $v"
done

# ---------- 2. HTP 架构探测 ----------
echo
echo "[2/6] HTP 架构探测"
echo "  包内固件库:"
for f in "$HERE"/lib/libggml-htp-v*.so; do
  [ -e "$f" ] && echo "    $(basename "$f")"
done
echo "  ggml-hexagon.so 存在: $([ -f "$HERE/lib/libggml-hexagon.so" ] && echo yes || echo no)"

# ---------- 3. 跑推理，抓 verbose ----------
echo
echo "[3/6] 运行推理（抓 ggml-hex verbose）..."
START=$(date +%s)
"$HERE/bin/llama-cli" \
  -m "$MODEL" \
  -p "1+1等于几？请直接回答数字。" \
  -n "$N" -ngl "$NGL" -t 4 \
  --no-warmup \
  > "$LOG" 2>&1
RC=$?
END=$(date +%s)
echo "  退出码=$RC  耗时=$((END-START))s"

if [ "$RC" != "0" ]; then
  echo "  !! 推理失败，日志尾部:"
  tail -n 25 "$LOG"
  exit 1
fi

# ---------- 4. 统计 supports-op ----------
echo
echo "[4/6] 算子支持统计"
YES=$(grep -c 'supports-op.*|yes' "$LOG" 2>/dev/null)
NO=$(grep -c 'supports-op.*|no' "$LOG" 2>/dev/null)
YES=${YES:-0}; NO=${NO:-0}
TOTAL=$((YES+NO))
echo "  上 NPU (yes): $YES"
echo "  回退 CPU(no): $NO"
if [ "$TOTAL" -gt 0 ]; then
  PCT=$((YES*100/TOTAL))
  echo "  NPU 覆盖率: ${PCT}%"
else
  echo "  NPU 覆盖率: 无法统计（没抓到 supports-op，确认 GGML_HEXAGON_VERBOSE 生效）"
fi

# ---------- 5. 被拒的算子长什么样 ----------
echo
echo "[5/6] 被拒的算子（去重后前 15 条）"
grep 'supports-op.*|no' "$LOG" 2>/dev/null \
  | sed 's/.*supports-op //' \
  | sort | uniq -c | sort -rn \
  | head -15 \
  | sed 's/^/  /'
[ "$NO" = "0" ] && echo "  （没有被拒的算子）"

# ---------- 6. 后端加载与速度 ----------
echo
echo "[6/6] 后端与速度"
echo "  加载的后端:"
grep -iE 'ggml_backend|backend.*load|Registered backend' "$LOG" 2>/dev/null | head -8 | sed 's/^/    /'
echo
echo "  offload 层数:"
grep -iE 'offload' "$LOG" 2>/dev/null | head -4 | sed 's/^/    /'
echo
echo "  token 速度:"
grep -iE 'eval time|tokens per second|t/s|tok/s' "$LOG" 2>/dev/null | tail -5 | sed 's/^/    /'
echo
echo "  Hexagon/HTP 相关:"
grep -iE 'hexagon|htp|cdsp' "$LOG" 2>/dev/null | head -6 | sed 's/^/    /'

echo
echo "=========================================="
echo " 完整日志: $LOG"
echo "=========================================="
