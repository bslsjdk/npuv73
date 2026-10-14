#!/system/bin/sh
# =============================================================
# diagnose-npu.sh —— NPU 卸载诊断
#
# 目的：回答三个问题
#   1. HTP 后端有没有被加载、架构探测成多少
#   2. 有多少层的算子被 NPU 接受 / 被拒（被拒的真实原因是什么）
#   3. NPU 到底带来多少提速（对比纯 CPU）
#
# 用法：
#   ./diagnose-npu.sh 模型.gguf
#   ./diagnose-npu.sh 模型.gguf 2048      # 指定 ctx 大小
#
# 输出：屏幕打印 + 保存 diag-report.txt
# 手机 /system/bin/sh 可直接跑（不依赖 bash 特性）
# =============================================================

set -u

HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
MODEL="${1:-}"
CTX="${2:-1024}"
OUT="${HERE}/diag-report.txt"

export LD_LIBRARY_PATH="${HERE}/lib:${LD_LIBRARY_PATH}"
export ADSP_LIBRARY_PATH="${HERE}/lib"

log() { echo "$@"; echo "$@" >> "$OUT"; }
hr()  { echo "----------------------------------------"; echo "----------------------------------------" >> "$OUT"; }

: > "$OUT"

log "===== llama.cpp Hexagon NPU 诊断报告 ====="
log "时间: $(date 2>/dev/null || echo unknown)"
log "工作目录: $HERE"
log "模型: ${MODEL:-（未指定）}"
log ""

# ---------- 0. 环境检查 ----------
hr
log "【0】环境与设备"
log ""

log "--- SoC ---"
for p in ro.board.platform ro.chipname ro.hardware.chipname ro.soc.model; do
  v="$(getprop $p 2>/dev/null)"
  [ -n "$v" ] && { echo "  $p = $v" >> "$OUT"; echo "  $p = $v"; }
done

log ""
log "--- HTP 固件库 ---"
ls -1 "${HERE}/lib"/libggml-htp-v*.so 2>/dev/null >> "$OUT"
ls -1 "${HERE}/lib"/libggml-htp-v*.so 2>/dev/null || log "  （无 htp 固件库）"

log ""
log "--- 内存 ---"
head -3 /proc/meminfo 2>/dev/null | sed 's/^/  /' >> "$OUT"

log ""
log "--- 磁盘剩余 ---"
df -h "${HERE}" 2>/dev/null | tail -1 | sed 's/^/  /' >> "$OUT"

# ---------- 1. 模型检查 ----------
hr
log "【1】模型"
log ""
if [ -z "$MODEL" ]; then
  log "未指定模型，跳过推理部分。"
  log "用法: ./diagnose-npu.sh /path/to/model.gguf"
  hr
  log "报告已保存: $OUT"
  exit 0
fi
if [ ! -f "$MODEL" ]; then
  log "!! 找不到模型: $MODEL"
  exit 1
fi
log "  路径: $MODEL"
log "  大小: $(ls -lh "$MODEL" 2>/dev/null | awk '{print $5}')"

# ---------- 2. 单次推理 + 采集后端日志 ----------
hr
log "【2】推理日志采集（GGML_HEXAGON_VERBOSE=1）"
log ""

export GGML_HEXAGON_VERBOSE=1

RUNLOG="${HERE}/diag-run.log"
: > "$RUNLOG"

log "执行: llama-cli -m <model> -p \"1+1等于几\" -n 32 -c $CTX -ngl 99 -t 4 -v"
echo ""

# -v 提升 llama 日志级别，否则 GGML_LOG_DEBUG 可能不输出
"${HERE}/bin/llama-cli" \
  -m "$MODEL" \
  -p "1+1等于几" \
  -n 32 -c "$CTX" -ngl 99 -t 4 -v \
  > "$RUNLOG" 2>&1
RC=$?

log "退出码: $RC  （0 = 成功）"
log ""

# ---------- 3. 解析结果 ----------
hr
log "【3】HTP 后端加载情况"
log ""

log "--- 含 hexagon / htp 的日志 ---"
grep -iE 'hexagon|htp|cdsp|dsp' "$RUNLOG" 2>/dev/null | head -25 | sed 's/^/  /' >> "$OUT"
grep -iE 'hexagon|htp|cdsp|dsp' "$RUNLOG" 2>/dev/null | head -25

log ""
log "--- 架构探测 ---"
grep -iE 'arch.*v[0-9]{2}|HTP version|opt_arch|v73|v75|v79|v81' "$RUNLOG" 2>/dev/null | head -10 | sed 's/^/  /' >> "$OUT"
grep -iE 'v73|v75|v79|v81|arch' "$RUNLOG" 2>/dev/null | head -10

hr
log "【4】层卸载统计（关键）"
log ""

log "--- offloaded 行 ---"
grep -iE 'offload' "$RUNLOG" 2>/dev/null | head -10 | sed 's/^/  /' >> "$OUT"
grep -iE 'offload' "$RUNLOG" 2>/dev/null | head -10

log ""
log "--- buffer 类型分布 ---"
grep -iE 'buffer type|Backend|backend' "$RUNLOG" 2>/dev/null | head -15 | sed 's/^/  /' >> "$OUT"
grep -iE 'buffer type' "$RUNLOG" 2>/dev/null | head -10

hr
log "【5】算子级接受/拒绝（per-op，最关键）"
log ""

YES=$(grep -c 'supports-op' "$RUNLOG" 2>/dev/null)
log "supports-op 总行数: ${YES}"

if [ "${YES:-0}" -gt 0 ]; then
  Y=$(grep 'supports-op' "$RUNLOG" 2>/dev/null | grep -c '|yes')
  N=$(grep 'supports-op' "$RUNLOG" 2>/dev/null | grep -c '|no')
  log ""
  log "  HTP 接受 (yes): $Y"
  log "  HTP 拒绝 (no) : $N"
  if [ "$((Y+N))" -gt 0 ]; then
    PCT=$((Y * 100 / (Y + N)))
    log "  NPU 覆盖率    : ${PCT}%"
  fi
  echo ""
  echo "  HTP 接受 (yes): $Y"
  echo "  HTP 拒绝 (no) : $N"
  echo "  NPU 覆盖率    : ${PCT:-?}%"
  echo ""

  log ""
  log "--- 被拒绝的算子（前 30 条，看 types 列判断是哪种量化格式被拒）---"
  grep 'supports-op' "$RUNLOG" 2>/dev/null | grep '|no' | head -30 | sed 's/^/  /' >> "$OUT"
  grep 'supports-op' "$RUNLOG" 2>/dev/null | grep '|no' | head -30

  log ""
  log "--- 被拒绝算子涉及的类型统计 ---"
  grep 'supports-op' "$RUNLOG" 2>/dev/null | grep '|no' \
    | sed 's/.*types=\([^|]*\)|.*/\1/' | sort | uniq -c | sort -rn | head -20 >> "$OUT"
  grep 'supports-op' "$RUNLOG" 2>/dev/null | grep '|no' \
    | sed 's/.*types=\([^|]*\)|.*/\1/' | sort | uniq -c | sort -rn | head -20
else
  log ""
  log "!! 没有抓到 supports-op 日志。"
  log "   原因通常是 GGML_LOG_DEBUG 未输出。请改用:"
  log "     GGML_HEXAGON_VERBOSE=2 ./bin/llama-cli ... -v"
  log "   或者这个构建编译时关掉了 debug 日志（release 常见）。"
  log "   此时请以【4】的 offloaded X/Y 为准。"
  echo ""
  echo "!! 没有抓到 supports-op 日志，以 offloaded 行为准"
fi

hr
log "【6】实际输出"
log ""
tail -25 "$RUNLOG" 2>/dev/null | sed 's/^/  /' >> "$OUT"
tail -25 "$RUNLOG" 2>/dev/null

# ---------- 7. 速度对比 ----------
hr
log "【7】速度对比：纯 CPU vs NPU"
log ""
log "跑 llama-bench 两次（各约 1-2 分钟）..."
echo "跑 llama-bench，请稍候..."

B0="${HERE}/diag-bench-cpu.log"
B99="${HERE}/diag-bench-npu.log"

"${HERE}/bin/llama-bench" -m "$MODEL" -ngl 0  -t 4 -n 64 -p 64 > "$B0" 2>&1
"${HERE}/bin/llama-bench" -m "$MODEL" -ngl 99 -t 4 -n 64 -p 64 > "$B99" 2>&1

log ""
log "--- 纯 CPU (-ngl 0) ---"
grep -iE 'tg|pp|tokens per second|t/s' "$B0" 2>/dev/null | tail -8 | sed 's/^/  /' >> "$OUT"
grep -iE 'tg|pp' "$B0" 2>/dev/null | tail -6
echo "  ^ CPU"

log ""
log "--- NPU (-ngl 99) ---"
grep -iE 'tg|pp|tokens per second|t/s' "$B99" 2>/dev/null | tail -8 | sed 's/^/  /' >> "$OUT"
grep -iE 'tg|pp' "$B99" 2>/dev/null | tail -6
echo "  ^ NPU"

log ""
log "判据: NPU 的 tg（token generation）速度应高于 CPU 50% 以上。"
log "      若持平或更慢，说明权重实际没上 NPU（多半是量化格式不对）。"

# ---------- 8. 结论 ----------
hr
log "【8】结论速查"
log ""
log "1) 若 offloaded 是 0/N        -> HTP 后端没加载，先查 libggml-hexagon.so 和 htp 固件"
log "2) 若 offloaded 有值但没提速   -> 量化格式不支持，算子静默回退 CPU（看【5】被拒类型）"
log "3) 若报错 AEE_EBADPARM       -> 固件库版本和 hexgon.so 不匹配，重编一次别混用"
log "4) 若 OOM                    -> 模型太大，减小 -ngl 或换小模型"
log "5) 若 IQ4_XS 出现在被拒类型里 -> 确认了：该格式 HTP 无内核，需转 Q4_K_M"
log ""
log "完整日志:"
log "  推理: $RUNLOG"
log "  CPU : $B0"
log "  NPU : $B99"
log ""
log "===== 报告结束: $OUT ====="

echo ""
echo "报告已保存: $OUT"
echo "把这个文件发出来即可分析。"
