#!/system/bin/sh
# hexlab — 第 1 层：静态硬件测绘（不进 DSP，纯读系统信息）
#
# 在手机上: sh static_probe.sh > /sdcard/hexlab-static.txt 2>&1
# 或 adb shell 里直接跑。
#
# 目的：在写任何 DSP 代码之前，先确认这台机器「声称」有什么。
# 凡是这里读不到的，不等于硬件没有 —— 只是接口没暴露，要靠第 2 层实测。

echo "################ 1. SoC / 板级 ################"
for p in ro.board.platform ro.chipname ro.soc.model ro.soc.manufacturer \
         ro.hardware ro.product.board ro.boot.hardware ro.vendor.product.device; do
    printf "%-28s %s\n" "$p" "$(getprop $p 2>/dev/null)"
done
echo
echo "--- CPU ---"
grep -m1 'Hardware' /proc/cpuinfo 2>/dev/null
echo "CPU 核心数: $(nproc 2>/dev/null)"
echo "--- 集群与频率 ---"
for c in /sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq; do
    [ -f "$c" ] || continue
    d="$(dirname $(dirname $c))"
    printf "%s max=%s kHz cur=%s kHz\n" "$(basename $d)" \
        "$(cat $c 2>/dev/null)" "$(cat $d/cpufreq/scaling_cur_freq 2>/dev/null)"
done

echo
echo "################ 2. DSP / NPU 设备节点 ################"
for n in /dev/adsprpc-smd /dev/cdsprpc-smd /dev/fastrpc-adsprpc-smd /dev/fastrpc-cdsprpc-smd \
         /dev/adsprpc-smd-secure /dev/cdsprpc-smd-secure; do
    if [ -e "$n" ]; then echo "存在: $n"; else echo "缺失: $n"; fi
done
echo
echo "--- remoteproc (DSP 固件) ---"
for r in /sys/class/remoteproc/remoteproc*; do
    [ -d "$r" ] || continue
    printf "%s firmware=%s state=%s\n" "$(basename $r)" \
        "$(cat $r/firmware 2>/dev/null)" "$(cat $r/state 2>/dev/null)"
done
echo
echo "--- 子系统重启计数（>0 说明 DSP 崩过）---"
for f in /sys/bus/msm_subsys/devices/*/restarts /sys/devices/*/subsys*/restarts; do
    [ -f "$f" ] || continue
    echo "$(basename $(dirname $f)): $(cat $f 2>/dev/null) 次"
done

echo
echo "################ 3. 厂商库（能推断什么）################"
echo "--- FastRPC 运行时 ---"
ls -la /vendor/lib64/libcdsprpc.so /vendor/lib64/libadsprpc.so \
       /vendor/lib64/librpcmem.so /system/lib64/libcdsprpc.so 2>/dev/null || echo "(未找到)"
echo
echo "--- QNN / HTP 相关 ---"
ls /vendor/lib64/ 2>/dev/null | grep -iE 'qnn|htp|hexagon|v68|v73|v75|v79' | head -30 || echo "(未找到)"
echo
echo "--- 其它 NPU 栈 ---"
ls /vendor/lib64/ 2>/dev/null | grep -iE 'mnn|ncnn|tflite|snpe|npu' | head -20 || echo "(未找到)"

echo
echo "################ 4. GPU（第二回退路径）################"
for g in /sys/class/kgsl/kgsl-3d0; do
    [ -d "$g" ] || continue
    echo "GPU: $(cat $g/gpu_model 2>/dev/null || echo '?')"
    echo "  最高频: $(cat $g/max_gpuclk 2>/dev/null) Hz"
    echo "  当前频: $(cat $g/gpuclk 2>/dev/null) Hz"
done
ls /vendor/lib64/libOpenCL.so /vendor/lib64/egl/libGLESv2_adreno.so 2>/dev/null || true

echo
echo "################ 5. 内存 ################"
grep -E 'MemTotal|MemAvailable|CmaTotal|SwapTotal' /proc/meminfo 2>/dev/null
echo "--- ION / DMA-BUF heaps ---"
ls /dev/dma_heap/ 2>/dev/null || echo "(无 dma_heap 节点)"

echo
echo "################ 6. 温控（决定长时间能不能跑满）################"
i=0
while [ $i -lt 32 ]; do
    t="/sys/class/thermal/thermal_zone$i"
    [ -d "$t" ] || { i=$((i+1)); continue; }
    ty="$(cat $t/type 2>/dev/null)"
    tp="$(cat $t/temp 2>/dev/null)"
    echo "zone$i [$ty] $tp"
    i=$((i+1))
done

echo
echo "################ 7. 内核 ################"
uname -a
cat /proc/cmdline 2>/dev/null | tr ' ' '\n' | grep -iE 'cma|ion|dmabuf|hugepage' | head -10

echo
echo "################ 8. llama.cpp 参考值 ################"
echo "运行自带 llama-cli 时加 GGML_HEXAGON_VERBOSE=1，"
echo "日志里的 'hwinfo: threads X, hvx Y, hmx Z, vtcm W MB' 是权威的域信息。"
echo "把它也记下来，和本脚本对照。"
