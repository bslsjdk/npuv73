#!/usr/bin/env python3
"""
为 llama.cpp 的 Hexagon(HTP) 后端添加 GGML_TYPE_IQ4_XS 支持。

设计要点
--------
IQ4_XS 结构（ggml-common.h:454）：
    ggml_half d;                   // 超块 scale
    uint16_t  scales_h;            // 8 个子块 scale 的高 2 位
    uint8_t   scales_l[QK_K/64];   // 8 个子块 scale 的低 4 位
    uint8_t   qs[QK_K/2];          // 128 字节 4-bit 索引

解码（ggml-quants.c:2744 dequantize_row_iq4_xs）：
    ls = ((scales_l[ib/2] >> 4*(ib%2)) & 0xf) | (((scales_h >> 2*ib) & 3) << 4)
    dl = d * (ls - 32)
    w  = dl * kvalues_iq4nl[q]

关键障碍
--------
1. 量化值走的是**非线性码表** kvalues_iq4nl（16 个非等间距值），
   不是 Q4_0/Q4_1 那种线性的 q-8 / q。
2. IQ4_XS **没有 min**，只有 scale。

因此它无法无损塞进 Q4_1 内核期望的 D*q+M 形式（那个只能表达等间距值），
更不能复用 Q4_K 的重排（Q4_K 有 (scale,min) 且是线性量化）。

采用的方案
----------
在 repack 阶段（ARM 侧一次性完成，不在推理热路径上）：
    解码每个 32 元素子块 -> float
    再按 ggml 的 Q4_0 量化器重新量化（w ≈ dd * (q - 8)）
    写入现成的 Q4_0 tiled 布局

这样 DSP 侧的 tiled_vec_dot_q4_0_32x1 内核无需任何改动即可运行。

代价：有一次 4.25bpw -> 4.5bpw 的再量化，存在额外精度损失。
这是"先跑通、再优化"的第一版；后续若要无损，需要为 IQ4_XS 写专用
HVX 内核（把码表融进 dequant 步骤）。

用法
----
    python3 apply_iq4xs.py <llama.cpp 源码根目录>
"""
import os
import sys

KVALUES = "-127, -104, -83, -65, -49, -35, -22, -10, 1, 13, 25, 38, 53, 69, 89, 113"

REPACK_FN = r'''
// ---------------------------------------------------------------------------
// IQ4_XS support
//
// IQ4_XS stores 4-bit indices into the non-linear kvalues_iq4nl codebook and
// carries only a per-sub-block scale (no minimum). That representation cannot
// be expressed as D*q+M, which is what the existing Q4_1/Q4_K tiled kernels
// consume, so the Q4_K repack cannot be reused here.
//
// Instead we dequantize each 32-element sub-block to float and requantize it
// with the reference Q4_0 quantizer (w ~= d * (q - 8)), emitting the stock
// Q4_0 tiled layout. The DSP side then runs the unmodified
// tiled_vec_dot_q4_0_32x1 kernel.
//
// Trade-off: this costs one extra requantization pass at load time and a small
// amount of accuracy versus a native IQ4_XS HVX kernel. It gets the format
// running on the NPU without touching any DSP code.
// ---------------------------------------------------------------------------
static const int8_t htp_iq4nl_kvalues[16] = { %s };

static void repack_iq4_xs_tiled(ggml_tensor * t, const void * data, size_t offset, size_t size) {
    GGML_ASSERT(offset == 0);

    const block_iq4_xs * src_matrix = (const block_iq4_xs *) data;
    const int64_t ne0 = t->ne[0];
    const int64_t ne1 = t->ne[1];
    const int64_t ne2 = t->ne[2];
    const int64_t ne3 = t->ne[3];
    const int64_t ne0_padded = hex_round_up(ne0, 32);
    const int64_t ne1_padded = hex_round_up(ne1, 32);

    GGML_ASSERT(ne0 %% QK_K == 0);

    const int    n_col_tiles  = (int) (ne1_padded / 32);
    const int    n_k_tiles    = (int) (ne0_padded / 32);
    const size_t tile_size    = HTP_MM_WEIGHT_TILE_SIZE_Q4_0;
    const size_t matrix_size  = (size_t) n_col_tiles * n_k_tiles * tile_size;
    const int64_t sb_per_row  = ne0 / QK_K;

    for (int i3 = 0; i3 < ne3; i3++) {
        for (int i2 = 0; i2 < ne2; i2++) {
            const block_iq4_xs * src_slice = src_matrix + (i3 * ne2 + i2) * (ne1 * sb_per_row);
            uint8_t * matrix_dst = (uint8_t *) t->data + (i3 * ne2 + i2) * matrix_size;

            memset(matrix_dst, 0, matrix_size);

            for (int64_t r = 0; r < ne1; r++) {
                const int ct  = (int) (r / 32);
                const int row = (int) (r %% 32);
                const block_iq4_xs * src_row = src_slice + r * sb_per_row;

                for (int kt = 0; kt < n_k_tiles; kt++) {
                    const int kt_local = kt %% 8;
                    const block_iq4_xs * b = &src_row[kt / 8];
                    uint8_t * tile_dst = matrix_dst + ((size_t) ct * n_k_tiles + kt) * tile_size;

                    // --- decode one 32-element sub-block ---
                    const float d = GGML_FP16_TO_FP32(b->d);
                    const int ls = ((b->scales_l[kt_local / 2] >> 4 * (kt_local %% 2)) & 0xf) |
                                   (((b->scales_h >> 2 * kt_local) & 3) << 4);
                    const float dl = d * (float) (ls - 32);

                    const uint8_t * qs_sub = b->qs + kt_local * 16;
                    float w[32];
                    for (int j = 0; j < 16; j++) {
                        w[j +  0] = dl * (float) htp_iq4nl_kvalues[qs_sub[j] & 0xf];
                        w[j + 16] = dl * (float) htp_iq4nl_kvalues[qs_sub[j] >>  4];
                    }

                    // --- requantize with the reference Q4_0 quantizer ---
                    float amax = 0.0f;
                    float max  = 0.0f;
                    for (int j = 0; j < 32; j++) {
                        const float v = w[j];
                        if (amax < fabsf(v)) { amax = fabsf(v); max = v; }
                    }
                    const float dd  = max / -8.0f;
                    const float idd = dd ? 1.0f / dd : 0.0f;

                    uint8_t q8[32];
                    for (int j = 0; j < 32; j++) {
                        const int qi = (int8_t) (w[j] * idd + 8.5f);
                        q8[j] = (uint8_t) (qi > 15 ? 15 : (qi < 0 ? 0 : qi));
                    }

                    // --- emit the stock Q4_0 tiled layout ---
                    for (int cp = 0; cp < 16; cp++) {
                        tile_dst[cp * 32 + row] = (uint8_t) ((q8[2 * cp + 1] << 4) | q8[2 * cp]);
                    }

                    ggml_half * scale_dst = (ggml_half *) (tile_dst + 512);
                    scale_dst[row] = GGML_FP32_TO_FP16(dd);
                }
            }
        }
    }

    GGML_UNUSED(size);
}

''' % (KVALUES, )


def sub1(s, old, new, label):
    """精确替换一次，失败则报错"""
    if old not in s:
        raise SystemExit('[iq4xs] 锚点未找到: %s' % label)
    return s.replace(old, new, 1)


def patch_file(path, fn):
    src = open(path, encoding='utf-8').read()
    out = fn(src)
    if out == src:
        print('  %s: 无变化' % os.path.basename(path))
    else:
        open(path, 'w', encoding='utf-8').write(out)
        print('  %s: 已打补丁' % os.path.basename(path))


def patch_hexagon(s):
    # 1) 插入码表 + repack 函数（放在 repack_q4_0_tiled 定义之前）
    s = sub1(s, 'static void repack_q4_0_tiled(', REPACK_FN.lstrip('\n') + 'static void repack_q4_0_tiled(', 'repack_q4_0_tiled 定义')

    # 2) 重排类型白名单
    s = sub1(s,
             '           type == GGML_TYPE_MXFP4 || type == GGML_TYPE_Q6_K ||\n'
             '           type == GGML_TYPE_Q4_K || type == GGML_TYPE_Q5_K ||\n'
             '           type == GGML_TYPE_Q3_K || type == GGML_TYPE_Q2_K;',
             '           type == GGML_TYPE_MXFP4 || type == GGML_TYPE_Q6_K ||\n'
             '           type == GGML_TYPE_Q4_K || type == GGML_TYPE_Q5_K ||\n'
             '           type == GGML_TYPE_Q3_K || type == GGML_TYPE_Q2_K ||\n'
             '           type == GGML_TYPE_IQ4_XS;',
             'is_repack_type')

    # 3) tiled row size —— 重排后是 Q4_0 布局，必须按 Q4_0 tile 计算，
    #    否则 buffer 会分配不足导致越界
    s = sub1(s,
             '    if (type == GGML_TYPE_Q3_K) {\n'
             '        return (size_t) (ne0 / 32) * (HTP_MM_WEIGHT_TILE_SIZE_Q3_K / 32);\n'
             '    }',
             '    if (type == GGML_TYPE_Q3_K) {\n'
             '        return (size_t) (ne0 / 32) * (HTP_MM_WEIGHT_TILE_SIZE_Q3_K / 32);\n'
             '    }\n'
             '    // IQ4_XS is repacked into the Q4_0 tiled layout\n'
             '    if (type == GGML_TYPE_IQ4_XS) {\n'
             '        return (size_t) (ne0 / 32) * (HTP_MM_WEIGHT_TILE_SIZE_Q4_0 / 32);\n'
             '    }',
             'tiled_row_size')

    # 4) 正向 repack 分派
    s = sub1(s,
             '        case GGML_TYPE_Q2_K:\n'
             '            repack_q2_K_tiled(tensor, data, 0, size);\n'
             '            break;',
             '        case GGML_TYPE_Q2_K:\n'
             '            repack_q2_K_tiled(tensor, data, 0, size);\n'
             '            break;\n'
             '\n'
             '        case GGML_TYPE_IQ4_XS:\n'
             '            repack_iq4_xs_tiled(tensor, data, 0, size);\n'
             '            break;',
             'repack_tensor_tiled')

    # 5) 反向 read-back 分派
    s = sub1(s,
             '        case GGML_TYPE_Q2_K:\n'
             '            GGML_ASSERT(offset == 0);\n'
             '            GGML_ASSERT(offset + size <= ggml_nbytes(tensor));\n'
             '            repack_tiled_q2_K(data, tensor, offset, size);',
             '        case GGML_TYPE_Q2_K:\n'
             '            GGML_ASSERT(offset == 0);\n'
             '            GGML_ASSERT(offset + size <= ggml_nbytes(tensor));\n'
             '            repack_tiled_q2_K(data, tensor, offset, size);\n'
             '\n'
             '        case GGML_TYPE_IQ4_XS:\n'
             '            GGML_ASSERT(offset == 0);\n'
             '            GGML_ASSERT(offset + size <= ggml_nbytes(tensor));\n'
             '            repack_tiled_q4_0(data, tensor, offset, size);',
             'get_tensor read-back')

    # 6) supports_op —— 普通 matmul
    s = sub1(s,
             '        case GGML_TYPE_Q4_K:\n'
             '        case GGML_TYPE_Q5_K:\n'
             '        case GGML_TYPE_Q6_K:\n'
             '        case GGML_TYPE_Q3_K:\n'
             '        case GGML_TYPE_Q2_K:\n'
             '            if (!ggml_is_contiguous(src0) || ggml_is_permuted(src0)) {\n'
             '                return false;\n'
             '            }\n'
             '\n'
             '            if (src0->ne[0] % ((src0->type == GGML_TYPE_Q6_K || src0->type == GGML_TYPE_Q5_K || src0->type == GGML_TYPE_Q4_K ||\n'
             '                                src0->type == GGML_TYPE_Q3_K || src0->type == GGML_TYPE_Q2_K) ? QK_K : 32)) {\n'
             '                return false;\n'
             '            }',
             '        case GGML_TYPE_Q4_K:\n'
             '        case GGML_TYPE_Q5_K:\n'
             '        case GGML_TYPE_Q6_K:\n'
             '        case GGML_TYPE_Q3_K:\n'
             '        case GGML_TYPE_Q2_K:\n'
             '        case GGML_TYPE_IQ4_XS:\n'
             '            if (!ggml_is_contiguous(src0) || ggml_is_permuted(src0)) {\n'
             '                return false;\n'
             '            }\n'
             '\n'
             '            if (src0->ne[0] % ((src0->type == GGML_TYPE_Q6_K || src0->type == GGML_TYPE_Q5_K || src0->type == GGML_TYPE_Q4_K ||\n'
             '                                src0->type == GGML_TYPE_Q3_K || src0->type == GGML_TYPE_Q2_K ||\n'
             '                                src0->type == GGML_TYPE_IQ4_XS) ? QK_K : 32)) {\n'
             '                return false;\n'
             '            }',
             'supports_op matmul')

    # 7) supports_op —— MoE 专家 (mul_mat_id)
    #    注意：这个 switch 结尾是 default: return false;，而普通 matmul 的
    #    结尾是 case GGML_TYPE_F16:，用 default 作为区分锚点。
    s = sub1(s,
             '        case GGML_TYPE_Q3_K:\n'
             '        case GGML_TYPE_Q2_K:\n'
             '            if (!ggml_is_contiguous(src0) || ggml_is_permuted(src0)) {\n'
             '                return false;\n'
             '            }\n'
             '\n'
             '            if (src0->ne[0] % ((src0->type == GGML_TYPE_Q6_K || src0->type == GGML_TYPE_Q5_K || src0->type == GGML_TYPE_Q4_K ||\n'
             '                                src0->type == GGML_TYPE_Q3_K || src0->type == GGML_TYPE_Q2_K) ? QK_K : 32)) {\n'
             '                return false;\n'
             '            }\n'
             '\n'
             '            if (!src0->buffer) {\n'
             '                sess->needs_repack.insert(src0);\n'
             '            }\n'
             '            break;\n'
             '\n'
             '        default:\n'
             '            return false;\n'
             '    }',
             '        case GGML_TYPE_Q3_K:\n'
             '        case GGML_TYPE_Q2_K:\n'
             '        case GGML_TYPE_IQ4_XS:\n'
             '            if (!ggml_is_contiguous(src0) || ggml_is_permuted(src0)) {\n'
             '                return false;\n'
             '            }\n'
             '\n'
             '            if (src0->ne[0] % ((src0->type == GGML_TYPE_Q6_K || src0->type == GGML_TYPE_Q5_K || src0->type == GGML_TYPE_Q4_K ||\n'
             '                                src0->type == GGML_TYPE_Q3_K || src0->type == GGML_TYPE_Q2_K ||\n'
             '                                src0->type == GGML_TYPE_IQ4_XS) ? QK_K : 32)) {\n'
             '                return false;\n'
             '            }\n'
             '\n'
             '            if (!src0->buffer) {\n'
             '                sess->needs_repack.insert(src0);\n'
             '            }\n'
             '            break;\n'
             '\n'
             '        default:\n'
             '            return false;\n'
             '    }',
             'supports_op mul_mat_id')

    return s


def patch_htp_ops(s):
    # 枚举值必须与 ggml_type 一致（GGML_TYPE_IQ4_XS == 23）
    return sub1(s,
                '    HTP_TYPE_IQ4_NL = 20,',
                '    HTP_TYPE_IQ4_NL = 20,\n'
                '    HTP_TYPE_IQ4_XS = 23,',
                'HTP_TYPE_IQ4_XS 枚举')


def patch_matmul_ops(s):
    # DSP 侧内核分派：IQ4_XS 重排后就是 Q4_0 tiled 布局
    return sub1(s,
                '        case HTP_TYPE_MXFP4:\n'
                '            mmctx->type         = "mxfp4_tiled-f32";\n'
                '            mmctx->vec_dot_32x1 = tiled_vec_dot_mxfp4_32x1;\n'
                '            return 0;',
                '        case HTP_TYPE_MXFP4:\n'
                '            mmctx->type         = "mxfp4_tiled-f32";\n'
                '            mmctx->vec_dot_32x1 = tiled_vec_dot_mxfp4_32x1;\n'
                '            return 0;\n'
                '        case HTP_TYPE_IQ4_XS:\n'
                '            mmctx->type         = "iq4xs_as_q4_0_tiled-f32";\n'
                '            mmctx->vec_dot_32x1 = tiled_vec_dot_q4_0_32x1;\n'
                '            return 0;',
                'hvx_mm_init_vec_dot')


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else 'llama.cpp'
    hexg = os.path.join(root, 'ggml/src/ggml-hexagon/ggml-hexagon.cpp')
    opsh = os.path.join(root, 'ggml/src/ggml-hexagon/htp/htp-ops.h')
    mmop = os.path.join(root, 'ggml/src/ggml-hexagon/htp/matmul-ops.c')

    for p in (hexg, opsh, mmop):
        if not os.path.isfile(p):
            raise SystemExit('[iq4xs] 找不到源文件: %s' % p)

    print('[iq4xs] 开始打补丁 -> %s' % root)
    patch_file(hexg, patch_hexagon)
    patch_file(opsh, patch_htp_ops)
    patch_file(mmop, patch_matmul_ops)
    print('[iq4xs] 完成')


if __name__ == '__main__':
    main()
