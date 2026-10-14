# 终端包内容验证 (run 38285906235)

## 目录树
dl
dl/bin
dl/bin/llama-bench
dl/bin/llama-perplexity
dl/bin/llama-quantize
dl/bin/llama-tokenize
dl/check-npu.sh
dl/lib
dl/lib/libc++_shared.so
dl/lib/libggml-base.so
dl/lib/libggml-cpu.so
dl/lib/libggml-hexagon.so
dl/lib/libggml-htp-v73.so
dl/lib/libggml-opencl.so
dl/lib/libggml.so
dl/lib/libllama-bench-impl.so
dl/lib/libllama-common.so
dl/lib/libllama-perplexity-impl.so
dl/lib/libllama-quantize-impl.so
dl/lib/libllama.so
dl/run.sh

## bin 内容
total 596
drwxr-xr-x 2 runner runner   4096 Oct 14 04:37 .
drwxr-xr-x 4 runner runner   4096 Oct 14 04:37 ..
-rw-r--r-- 1 runner runner   7392 Oct 14 04:37 llama-bench
-rw-r--r-- 1 runner runner   7472 Oct 14 04:37 llama-perplexity
-rw-r--r-- 1 runner runner   7400 Oct 14 04:37 llama-quantize
-rw-r--r-- 1 runner runner 577240 Oct 14 04:37 llama-tokenize

## lib 内容
total 137712
drwxr-xr-x 2 runner runner     4096 Oct 14 04:37 .
drwxr-xr-x 4 runner runner     4096 Oct 14 04:37 ..
-rw-r--r-- 1 runner runner  9290184 Oct 14 04:37 libc++_shared.so
-rw-r--r-- 1 runner runner  7783552 Oct 14 04:37 libggml-base.so
-rw-r--r-- 1 runner runner  4353616 Oct 14 04:37 libggml-cpu.so
-rw-r--r-- 1 runner runner  7404592 Oct 14 04:37 libggml-hexagon.so
-rw-r--r-- 1 runner runner   857128 Oct 14 04:37 libggml-htp-v73.so
-rw-r--r-- 1 runner runner 13517560 Oct 14 04:37 libggml-opencl.so
-rw-r--r-- 1 runner runner   392432 Oct 14 04:37 libggml.so
-rw-r--r-- 1 runner runner  3733368 Oct 14 04:37 libllama-bench-impl.so
-rw-r--r-- 1 runner runner 53377016 Oct 14 04:37 libllama-common.so
-rw-r--r-- 1 runner runner  1622744 Oct 14 04:37 libllama-perplexity-impl.so
-rw-r--r-- 1 runner runner  1011640 Oct 14 04:37 libllama-quantize-impl.so
-rw-r--r-- 1 runner runner 37640432 Oct 14 04:37 libllama.so

## 总体积
136M	dl
## 最大的 10 个文件
50.9 MB  dl/lib/libllama-common.so
35.9 MB  dl/lib/libllama.so
12.9 MB  dl/lib/libggml-opencl.so
8.9 MB  dl/lib/libc++_shared.so
7.4 MB  dl/lib/libggml-base.so
7.1 MB  dl/lib/libggml-hexagon.so
4.2 MB  dl/lib/libggml-cpu.so
3.6 MB  dl/lib/libllama-bench-impl.so
1.5 MB  dl/lib/libllama-perplexity-impl.so
1.0 MB  dl/lib/libllama-quantize-impl.so

## ELF 架构校验
--- llama-bench ---
  Class:                             ELF64
  Type:                              DYN (Position-Independent Executable file)
  Machine:                           AArch64
--- llama-perplexity ---
  Class:                             ELF64
  Type:                              DYN (Position-Independent Executable file)
  Machine:                           AArch64
--- llama-quantize ---
  Class:                             ELF64
  Type:                              DYN (Position-Independent Executable file)
  Machine:                           AArch64
--- llama-tokenize ---
  Class:                             ELF64
  Type:                              DYN (Position-Independent Executable file)
  Machine:                           AArch64

## 缺失依赖检查
OK   llama-bench -> libllama-bench-impl.so
OK   llama-bench -> libllama-common.so
OK   llama-bench -> libllama.so
OK   llama-bench -> libggml.so
OK   llama-bench -> libggml-cpu.so
OK   llama-bench -> libggml-opencl.so
OK   llama-bench -> libggml-hexagon.so
OK   llama-bench -> libggml-base.so
MISS llama-bench -> libm.so
MISS llama-bench -> libdl.so
MISS llama-bench -> libc.so
OK   llama-perplexity -> libllama-perplexity-impl.so
OK   llama-perplexity -> libllama-common.so
OK   llama-perplexity -> libllama.so
OK   llama-perplexity -> libggml.so
OK   llama-perplexity -> libggml-cpu.so
OK   llama-perplexity -> libggml-opencl.so
OK   llama-perplexity -> libggml-hexagon.so
OK   llama-perplexity -> libggml-base.so
MISS llama-perplexity -> libm.so
MISS llama-perplexity -> libdl.so
MISS llama-perplexity -> libc.so
OK   llama-quantize -> libllama-quantize-impl.so
OK   llama-quantize -> libllama-common.so
OK   llama-quantize -> libllama.so
OK   llama-quantize -> libggml.so
OK   llama-quantize -> libggml-cpu.so
OK   llama-quantize -> libggml-opencl.so
OK   llama-quantize -> libggml-hexagon.so
OK   llama-quantize -> libggml-base.so
MISS llama-quantize -> libm.so
MISS llama-quantize -> libdl.so
MISS llama-quantize -> libc.so
OK   llama-tokenize -> libllama-common.so
OK   llama-tokenize -> libllama.so
OK   llama-tokenize -> libggml.so
OK   llama-tokenize -> libggml-cpu.so
OK   llama-tokenize -> libggml-opencl.so
OK   llama-tokenize -> libggml-hexagon.so
OK   llama-tokenize -> libggml-base.so
MISS llama-tokenize -> libm.so
MISS llama-tokenize -> libdl.so
MISS llama-tokenize -> libc.so
