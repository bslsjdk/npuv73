// hexlab — ARM 侧宿主
//
// 通过 FastRPC 把我们自己的 skel 加载进 cDSP，跑微基准并计时。
//
// 用法:
//   export ADSP_LIBRARY_PATH=/path/to/hexlab/dsp
//   ./hexprobe_host [-o result.csv]
//
// 关键：我们刻意 dlopen libcdsprpc.so 并自己提供 remote_handle64_* 符号，
// 这样 qaic 生成的 stub 能直接链接，且不依赖 NDK 里没有的库。

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "hexprobe.h"

// ------------------------------------------------ FastRPC 符号桥接

typedef int (*rh_open_t)(const char *, remote_handle64 *);
typedef int (*rh_invoke_t)(remote_handle64, uint32, remote_arg *);
typedef int (*rh_close_t)(remote_handle64);

static rh_open_t   p_open   = NULL;
static rh_invoke_t p_invoke = NULL;
static rh_close_t  p_close  = NULL;

int remote_handle64_open(const char * name, remote_handle64 * ph) {
    return p_open ? p_open(name, ph) : -1;
}
int remote_handle64_invoke(remote_handle64 h, uint32 s, remote_arg * pra) {
    return p_invoke ? p_invoke(h, s, pra) : -1;
}
int remote_handle64_close(remote_handle64 h) {
    return p_close ? p_close(h) : -1;
}

static int load_fastrpc(void) {
    const char * names[] = {
        "libcdsprpc.so",
        "libadsprpc.so",
        "/vendor/lib64/libcdsprpc.so",
        "/system/lib64/libcdsprpc.so",
        NULL
    };
    for (int i = 0; names[i]; i++) {
        void * h = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
        if (!h) continue;
        p_open   = (rh_open_t)   dlsym(h, "remote_handle64_open");
        p_invoke = (rh_invoke_t) dlsym(h, "remote_handle64_invoke");
        p_close  = (rh_close_t)  dlsym(h, "remote_handle64_close");
        if (p_open && p_invoke && p_close) {
            fprintf(stderr, "[host] FastRPC via %s\n", names[i]);
            return 0;
        }
        dlclose(h);
        p_open = p_invoke = p_close = NULL;
    }
    fprintf(stderr, "[host] 找不到 libcdsprpc.so / libadsprpc.so\n");
    return -1;
}

// ------------------------------------------------ 计时

static double now_usec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double) ts.tv_sec * 1e6 + (double) ts.tv_nsec / 1e3;
}

// ------------------------------------------------ 主流程

static const char * bench_name(uint32 which) {
    switch (which) {
        case 1: return "empty";
        case 2: return "int8_add";
        case 3: return "int16_mpy";
        case 4: return "int4_dot";
        case 5: return "memcpy";
        case 6: return "gemm_int8";
        case 7: return "gemm_int4";
        default: return "?";
    }
}

struct row {
    const char * name;
    uint32       which;
    uint32       len;
    uint64       cycles;
    uint64       ops;
    uint32       chk;
    double       usec;
};

static int run_bench(remote_handle64 h, uint32 which, uint32 iters, uint32 len, struct row * out) {
    uint64 cycles = 0, ops = 0;
    uint32 chk = 0;

    // 预热一次，避免首次缺页 / DSP 侧首次分配计入
    AEEResult r = hexprobe_bench(h, which, iters, len, &cycles, &ops, &chk);
    if (r != AEE_SUCCESS) return (int) r;

    double t0 = now_usec();
    r = hexprobe_bench(h, which, iters, len, &cycles, &ops, &chk);
    double t1 = now_usec();
    if (r != AEE_SUCCESS) return (int) r;

    out->name   = bench_name(which);
    out->which  = which;
    out->len    = len;
    out->cycles = cycles;
    out->ops    = ops;
    out->chk    = chk;
    out->usec   = t1 - t0;
    return 0;
}

int main(int argc, char ** argv) {
    const char * out_path = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-o") && i + 1 < argc) out_path = argv[++i];
    }

    if (load_fastrpc() != 0) return 2;

    remote_handle64 h = 0;
    int rc = hexprobe_open("file:///libhexprobe.so?hexprobe_skel_handle_invoke&_modver=1.0", &h);
    if (rc != 0 || h == 0) {
        fprintf(stderr, "[host] hexprobe_open 失败: %d\n", rc);
        fprintf(stderr, "[host] 确认 ADSP_LIBRARY_PATH 指向放 libhexprobe.so 的目录\n");
        return 3;
    }
    fprintf(stderr, "[host] skel 已加载\n");

    // ---- 第 1 层：硬件身份 ----
    uint32 hvx_arch = 0, dsp_arch = 0, vec_bytes = 0, hvx_on = 0;
    AEEResult r = hexprobe_hwinfo(h, &hvx_arch, &dsp_arch, &vec_bytes, &hvx_on);
    printf("=== 第 1 层 硬件身份 ===\n");
    if (r == AEE_SUCCESS) {
        printf("DSP 架构版本   : v%u\n", dsp_arch);
        printf("HVX 架构版本   : %u%s\n", hvx_arch, hvx_on ? " (已启用)" : " (未启用)");
        printf("HVX 向量宽度   : %u 字节\n", vec_bytes);
    } else {
        printf("hwinfo 失败: 0x%x\n", r);
    }

    // ---- 频率标定 ----
    double mhz = 0.0;
    {
        uint64 c = 0; uint32 it = 0;
        double t0 = now_usec();
        r = hexprobe_spin(h, 20000000u, &c, &it);   // 约 20M 周期
        double t1 = now_usec();
        if (r == AEE_SUCCESS && c > 0) {
            mhz = (double) c / (t1 - t0);
            printf("实测 DSP 频率  : %.1f MHz (空转 %llu 周期 / %.0f us)\n", mhz,
                   (unsigned long long) c, t1 - t0);
        } else {
            printf("spin 失败: 0x%x\n", r);
        }
    }

    // ---- 第 2 层：微基准 ----
    printf("\n=== 第 2 层 微基准 ===\n");

    const uint32 lens[] = { 1024, 4096, 16384, 65536, 262144, 1048576 };
    const int n_lens = (int) (sizeof(lens) / sizeof(lens[0]));

    FILE * csv = NULL;
    if (out_path) {
        csv = fopen(out_path, "w");
        if (csv) fprintf(csv, "name,which,len,iters,cycles,ops,usec,mhz,chk,cycles_per_op,gops\n");
    }

    printf("%-12s %8s %12s %12s %10s %10s %8s\n",
           "bench", "len", "cycles", "usec", "MHz", "Gop/s", "chk");

    for (uint32 which = 1; which <= 7; which++) {
        uint32 iters = 8;
        if (which == 6 || which == 7) iters = 2;   // GEMM 慢，少跑几次
        int count = (which == 1) ? 1 : n_lens;

        for (int li = 0; li < count; li++) {
            uint32 len = (which == 1) ? 0 : lens[li];
            if (which == 6) len = (lens[li] > 8192) ? 8192 : lens[li];
            if (which == 7) len = (lens[li] > 4096) ? 4096 : lens[li];

            struct row row;
            int e = run_bench(h, which, iters, len, &row);
            if (e != 0) {
                printf("%-12s %8u  失败 0x%x\n", bench_name(which), len, e);
                continue;
            }
            double cpo   = row.ops ? (double) row.cycles / (double) row.ops : 0.0;
            double gops  = row.usec > 0 ? ((double) row.ops / row.usec / 1000.0) : 0.0;
            double cur_mhz = row.usec > 0 ? (double) row.cycles / row.usec : 0.0;

            printf("%-12s %8u %12llu %12.1f %10.1f %10.3f %08x\n",
                   row.name, row.len,
                   (unsigned long long) row.cycles,
                   row.usec, cur_mhz, gops, row.chk);

            if (csv) {
                fprintf(csv, "%s,%u,%u,%u,%llu,%llu,%.1f,%.1f,%u,%.4f,%.4f\n",
                        row.name, row.which, row.len, iters,
                        (unsigned long long) row.cycles,
                        (unsigned long long) row.ops,
                        row.usec, cur_mhz, row.chk, cpo, gops);
            }
        }
    }

    // ---- 长时间运行：看降频 ----
    printf("\n=== 持续负载 / 降频观察 ===\n");
    for (uint32 target = 50000000u; target <= 500000000u; target *= 10u) {
        uint64 c = 0; uint32 it = 0;
        double t0 = now_usec();
        r = hexprobe_spin(h, target, &c, &it);
        double t1 = now_usec();
        if (r == AEE_SUCCESS && c > 0) {
            printf("目标 %9u 周期 -> 实跑 %12llu 周期, %10.1f ms, 平均 %.1f MHz\n",
                   target, (unsigned long long) c, (t1 - t0) / 1000.0,
                   (double) c / (t1 - t0));
        }
    }

    if (csv) { fclose(csv); printf("\nCSV 已写入: %s\n", out_path); }

    hexprobe_close(h);
    return 0;
}
