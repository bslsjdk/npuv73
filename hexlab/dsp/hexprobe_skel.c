// hexlab — DSP(cDSP) 侧探测实现
//
// 用 hexagon-clang 编译成 libhexprobe.so 的 skel，
// 通过 FastRPC 被 ARM 侧 dlopen 加载（无需签名，走 unsigned PD）。
//
// 设计原则：
//   * 每个基准都返回 cycles（DSP 周期计数器 C15:14）
//   * 墙钟时间交给 ARM 侧测，避免 QuRT 计时 API 的不确定性
//   * 所有结果带 checksum，保证编译器没把循环优化掉
//   * HVX 部分用宏开关，编译不过可以单独关掉，不影响其余基准

#include "hexprobe.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <qurt.h>

#include "hexagon_types.h"

#if defined(__HVX_ARCH__) && __HVX_ARCH__ >= 68
#define HP_HVX 1
#include "hexagon_protos.h"
#else
#define HP_HVX 0
#endif

// vrmpy 是字节点积的原生指令，是本文件里唯一有编译风险的内联函数。
// 如果 CI 报这个符号不存在，用 -DHP_HAVE_VRMPY=0 关掉，其余基准照跑。
#ifndef HP_HAVE_VRMPY
#define HP_HAVE_VRMPY 1
#endif

#define HP_VLEN 128u   // HVX 向量字节数（v6x 之后固定 128）
#define HP_BUF_BYTES (1u << 20)  // 1 MiB 工作缓冲

// ---------------------------------------------------------------- 计时

static inline uint64_t hp_cycles(void) {
    uint64_t c = 0;
    asm volatile(" %0 = c15:14\n" : "=r"(c));
    return c;
}

// ---------------------------------------------------------------- 缓冲

static uint8_t * g_a = NULL;
static uint8_t * g_b = NULL;
static uint8_t * g_c = NULL;

static int hp_ensure_bufs(void) {
    if (g_a) return 0;
    g_a = (uint8_t *) malloc(HP_BUF_BYTES);
    g_b = (uint8_t *) malloc(HP_BUF_BYTES);
    g_c = (uint8_t *) malloc(HP_BUF_BYTES);
    if (!g_a || !g_b || !g_c) return -1;
    // 用非平凡填充，避免全零让任何捷径得逞
    for (uint32_t i = 0; i < HP_BUF_BYTES; i++) {
        g_a[i] = (uint8_t) (i * 7 + 1);
        g_b[i] = (uint8_t) (i * 3 + 5);
    }
    memset(g_c, 0, HP_BUF_BYTES);
    return 0;
}

static inline uint32_t hp_clamp_len(uint32_t len) {
    if (len == 0) len = HP_BUF_BYTES;
    if (len > HP_BUF_BYTES) len = HP_BUF_BYTES;
    return len;
}

// ---------------------------------------------------------------- 基准 1: 空

static uint64_t hp_bench_empty(uint32_t iters, uint32_t len, uint32_t * chk, uint64_t * ops) {
    (void) len;
    uint32_t acc = 0;
    uint64_t t0 = hp_cycles();
    for (uint32_t i = 0; i < iters; i++) {
        acc += i;   // 纯开销，不碰内存
    }
    uint64_t t1 = hp_cycles();
    *chk = acc;
    *ops = iters;
    return t1 - t0;
}

// ---------------------------------------------------------------- 基准 2: INT8 向量加

static uint64_t hp_bench_int8(uint32_t iters, uint32_t len, uint32_t * chk, uint64_t * ops) {
    uint32_t n = hp_clamp_len(len);
    uint8_t * a = g_a, * b = g_b, * c = g_c;
    uint32_t acc = 0;
    uint64_t t0 = hp_cycles();
    for (uint32_t it = 0; it < iters; it++) {
#if HP_HVX
        uint32_t i = 0;
        for (; i + HP_VLEN <= n; i += HP_VLEN) {
            HVX_Vector va = *(HVX_Vector *) (a + i);
            HVX_Vector vb = *(HVX_Vector *) (b + i);
            *(HVX_Vector *) (c + i) = Q6_Vb_vadd_VbVb(va, vb);
        }
        for (; i < n; i++) c[i] = (uint8_t) (a[i] + b[i]);
#else
        for (uint32_t i = 0; i < n; i++) c[i] = (uint8_t) (a[i] + b[i]);
#endif
        acc += c[0];
    }
    uint64_t t1 = hp_cycles();
    *chk = acc;
    *ops = (uint64_t) iters * n;
    return t1 - t0;
}

// ---------------------------------------------------------------- 基准 3: INT16 乘加

static uint64_t hp_bench_int16(uint32_t iters, uint32_t len, uint32_t * chk, uint64_t * ops) {
    uint32_t nbytes = hp_clamp_len(len) & ~1u;
    uint32_t n = nbytes / 2;              // 元素数
    uint16_t * a = (uint16_t *) g_a;
    uint16_t * b = (uint16_t *) g_b;
    uint16_t * c = (uint16_t *) g_c;
    uint32_t acc = 0;
    uint64_t t0 = hp_cycles();
    for (uint32_t it = 0; it < iters; it++) {
#if HP_HVX
        uint32_t i = 0;
        for (; i + (HP_VLEN / 2) <= n; i += (HP_VLEN / 2)) {
            HVX_Vector va = *(HVX_Vector *) (a + i);
            HVX_Vector vb = *(HVX_Vector *) (b + i);
            HVX_Vector vp = Q6_Vh_vmpy_VhVh(va, vb);
            *(HVX_Vector *) (c + i) = vp;
        }
        for (; i < n; i++) c[i] = (uint16_t) (a[i] * b[i]);
#else
        for (uint32_t i = 0; i < n; i++) c[i] = (uint16_t) (a[i] * b[i]);
#endif
        acc += c[0];
    }
    uint64_t t1 = hp_cycles();
    *chk = acc;
    *ops = (uint64_t) iters * n;
    return t1 - t0;
}

// ---------------------------------------------------------------- 基准 4: INT4 打包点积
//
// 布局：一个字节装两个 4-bit 权重（低 4 位 = 偶数下标，高 4 位 = 奇数下标）
// 流程：load 128B(256 个 int4) → 拆低/高 nibble → 各自与全 1 做 vrmpy
//       → 得到每 32-bit lane 的部分和 → 末尾横向归约
// 这一步回答的问题：解包能否和点积融合，还是必须落地成中间数组

static uint64_t hp_bench_int4(uint32_t iters, uint32_t len, uint32_t * chk, uint64_t * ops) {
    uint32_t n = hp_clamp_len(len);       // 打包字节数
    uint8_t * a = g_a;
    uint32_t acc = 0;
    uint64_t t0 = hp_cycles();
    for (uint32_t it = 0; it < iters; it++) {
#if HP_HVX
    #if HP_HAVE_VRMPY
        HVX_Vector ones = Q6_Vb_vsplat_R(1);
        HVX_Vector mask = Q6_Vb_vsplat_R(0x0F);
        HVX_Vector tot  = Q6_V_vzero();
        uint32_t i = 0;
        for (; i + HP_VLEN <= n; i += HP_VLEN) {
            HVX_Vector v  = *(HVX_Vector *) (a + i);
            HVX_Vector lo = Q6_V_vand_VV(v, mask);
            HVX_Vector hi = Q6_Vb_vlsr_VbR(v, 4);
            tot = Q6_Vuw_vadd_VuwVuw(tot, Q6_Vuw_vrmpy_VubVub(lo, ones));
            tot = Q6_Vuw_vadd_VuwVuw(tot, Q6_Vuw_vrmpy_VubVub(hi, ones));
        }
        // 横向归约
        uint32_t tmp[32];
        *(HVX_Vector *) tmp = tot;
        uint32_t s = 0;
        for (int k = 0; k < 32; k++) s += tmp[k];
        for (; i < n; i++) { s += (a[i] & 0x0F) + (a[i] >> 4); }
        acc += s;
    #else
        uint32_t s = 0;
        for (uint32_t i = 0; i < n; i++) s += (a[i] & 0x0F) + (a[i] >> 4);
        acc += s;
    #endif
#else
        uint32_t s = 0;
        for (uint32_t i = 0; i < n; i++) s += (a[i] & 0x0F) + (a[i] >> 4);
        acc += s;
#endif
    }
    uint64_t t1 = hp_cycles();
    *chk = acc;
    *ops = (uint64_t) iters * n * 2;      // 实际 int4 元素数
    return t1 - t0;
}

// ---------------------------------------------------------------- 基准 5: memcpy 带宽

static uint64_t hp_bench_memcpy(uint32_t iters, uint32_t len, uint32_t * chk, uint64_t * ops) {
    uint32_t n = hp_clamp_len(len);
    uint32_t acc = 0;
    uint64_t t0 = hp_cycles();
    for (uint32_t it = 0; it < iters; it++) {
        memcpy(g_c, g_a, n);
        acc += g_c[0] + g_c[n - 1];
    }
    uint64_t t1 = hp_cycles();
    *chk = acc;
    *ops = (uint64_t) iters * n;
    return t1 - t0;
}

// ---------------------------------------------------------------- GEMM
//
// M = N = 16, K = len（字节）。B 按列存：B[j*K + k]
// 用 int8 权重 + vrmpy 累加；返回总 MAC 数供算 GOPS

#define HP_GEMM_M 16u
#define HP_GEMM_N 16u

static uint64_t hp_bench_gemm_int8(uint32_t iters, uint32_t k, uint32_t * chk, uint64_t * ops) {
    if (k == 0) k = 512;
    if (k > 8192) k = 8192;
    const uint8_t * A = g_a;                       // M*K
    const uint8_t * B = g_b;                       // N*K
    int32_t C[HP_GEMM_M * HP_GEMM_N];
    uint32_t acc = 0;
    uint64_t t0 = hp_cycles();
    for (uint32_t it = 0; it < iters; it++) {
        for (uint32_t i = 0; i < HP_GEMM_M; i++) {
            const uint8_t * arow = A + i * k;
            for (uint32_t j = 0; j < HP_GEMM_N; j++) {
                const uint8_t * bcol = B + j * k;
                int32_t sum = 0;
                uint32_t kk = 0;
#if HP_HVX && HP_HAVE_VRMPY
                for (; kk + HP_VLEN <= k; kk += HP_VLEN) {
                    HVX_Vector va = *(HVX_Vector *) (arow + kk);
                    HVX_Vector vb = *(HVX_Vector *) (bcol + kk);
                    HVX_Vector vp = Q6_Vuw_vrmpy_VubVub(va, vb);
                    uint32_t tmp[32];
                    *(HVX_Vector *) tmp = vp;
                    for (int q = 0; q < 32; q++) sum += (int32_t) tmp[q];
                }
#endif
                for (; kk < k; kk++) sum += (int32_t) arow[kk] * (int32_t) bcol[kk];
                C[i * HP_GEMM_N + j] = sum;
            }
        }
        acc += (uint32_t) C[0];
    }
    uint64_t t1 = hp_cycles();
    *chk = acc;
    *ops = (uint64_t) iters * HP_GEMM_M * HP_GEMM_N * k;   // MAC 数
    return t1 - t0;
}

// INT4 版：A/B 都是打包字节，K 以「打包字节数」计 → 实际 K = 2*k
static uint64_t hp_bench_gemm_int4(uint32_t iters, uint32_t pk, uint32_t * chk, uint64_t * ops) {
    if (pk == 0) pk = 256;
    if (pk > 4096) pk = 4096;
    const uint8_t * A = g_a;
    const uint8_t * B = g_b;
    int32_t C[HP_GEMM_M * HP_GEMM_N];
    uint32_t acc = 0;
    uint64_t t0 = hp_cycles();
    for (uint32_t it = 0; it < iters; it++) {
        for (uint32_t i = 0; i < HP_GEMM_M; i++) {
            const uint8_t * arow = A + i * pk;
            for (uint32_t j = 0; j < HP_GEMM_N; j++) {
                const uint8_t * bcol = B + j * pk;
                int32_t sum = 0;
                for (uint32_t kk = 0; kk < pk; kk++) {
                    uint8_t ab = arow[kk], bb = bcol[kk];
                    sum += (int32_t) (ab & 0x0F) * (int32_t) (bb & 0x0F);
                    sum += (int32_t) (ab >> 4)     * (int32_t) (bb >> 4);
                }
                C[i * HP_GEMM_N + j] = sum;
            }
        }
        acc += (uint32_t) C[0];
    }
    uint64_t t1 = hp_cycles();
    *chk = acc;
    *ops = (uint64_t) iters * HP_GEMM_M * HP_GEMM_N * pk * 2;
    return t1 - t0;
}

// ---------------------------------------------------------------- IDL 实现

AEEResult hexprobe_hwinfo(remote_handle64 h,
                          uint32 * hvx_arch,
                          uint32 * dsp_arch,
                          uint32 * vec_bytes,
                          uint32 * reserved) {
    (void) h;
    if (hvx_arch)  *hvx_arch = (uint32_t) (__HVX_ARCH__);
    if (dsp_arch)  *dsp_arch = (uint32_t) (__HEXAGON_ARCH__);
    if (vec_bytes) *vec_bytes = (uint32_t) HP_VLEN;
    if (reserved)  *reserved = (uint32_t) HP_HVX;
    return AEE_SUCCESS;
}

AEEResult hexprobe_bench(remote_handle64 h,
                         uint32 which,
                         uint32 iters,
                         uint32 len,
                         uint64 * cycles,
                         uint64 * ops,
                         uint32 * checksum) {
    (void) h;
    if (hp_ensure_bufs() != 0) return AEE_ENOMEMORY;
    if (iters == 0) iters = 1;

    uint64_t c = 0, o = 0;
    uint32_t chk = 0;

    switch (which) {
        case 1:  c = hp_bench_empty   (iters, len, &chk, &o); break;
        case 2:  c = hp_bench_int8    (iters, len, &chk, &o); break;
        case 3:  c = hp_bench_int16   (iters, len, &chk, &o); break;
        case 4:  c = hp_bench_int4    (iters, len, &chk, &o); break;
        case 5:  c = hp_bench_memcpy  (iters, len, &chk, &o); break;
        case 6:  c = hp_bench_gemm_int8(iters, len, &chk, &o); break;
        case 7:  c = hp_bench_gemm_int4(iters, len, &chk, &o); break;
        default: return AEE_EBADPARM;
    }

    if (cycles)   *cycles   = c;
    if (ops)      *ops      = o;
    if (checksum) *checksum = chk;
    return AEE_SUCCESS;
}

AEEResult hexprobe_spin(remote_handle64 h,
                        uint32 approx_cycles,
                        uint64 * cycles,
                        uint32 * iters) {
    (void) h;
    if (approx_cycles == 0) approx_cycles = 1000000;
    uint64_t target = (uint64_t) approx_cycles;
    uint64_t t0 = hp_cycles();
    uint32_t n = 0;
    uint64_t acc = 0;
    while (1) {
        acc += (uint64_t) n;                 // 防止被优化掉
        n++;
        if ((hp_cycles() - t0) >= target) break;
        if (n == 0xFFFFFFFFu) break;
    }
    uint64_t t1 = hp_cycles();
    if (cycles) *cycles = t1 - t0 + acc * 0;
    if (iters)  *iters  = n;
    return AEE_SUCCESS;
}
