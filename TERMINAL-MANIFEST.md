# 终端包内容验证 (run 38522331871)

## 目录树
dl
dl/bin
dl/bin/llama-bench
dl/bin/llama-cli
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
dl/lib/libllama-cli-impl.so
dl/lib/libllama-common.so
dl/lib/libllama-perplexity-impl.so
dl/lib/libllama-quantize-impl.so
dl/lib/libllama.so
dl/run.sh

## bin 内容
total 604
drwxr-xr-x 2 runner runner   4096 Oct 14 06:37 .
drwxr-xr-x 4 runner runner   4096 Oct 14 06:37 ..
-rw-r--r-- 1 runner runner   7392 Oct 14 06:37 llama-bench
-rw-r--r-- 1 runner runner   7464 Oct 14 06:37 llama-cli
-rw-r--r-- 1 runner runner   7472 Oct 14 06:37 llama-perplexity
-rw-r--r-- 1 runner runner   7400 Oct 14 06:37 llama-quantize
-rw-r--r-- 1 runner runner 577240 Oct 14 06:37 llama-tokenize

## lib 内容
total 140996
drwxr-xr-x 2 runner runner     4096 Oct 14 06:37 .
drwxr-xr-x 4 runner runner     4096 Oct 14 06:37 ..
-rw-r--r-- 1 runner runner  9290184 Oct 14 06:37 libc++_shared.so
-rw-r--r-- 1 runner runner  7783792 Oct 14 06:37 libggml-base.so
-rw-r--r-- 1 runner runner  4353616 Oct 14 06:37 libggml-cpu.so
-rw-r--r-- 1 runner runner  7412120 Oct 14 06:37 libggml-hexagon.so
-rw-r--r-- 1 runner runner   852040 Oct 14 06:37 libggml-htp-v73.so
-rw-r--r-- 1 runner runner 13518624 Oct 14 06:37 libggml-opencl.so
-rw-r--r-- 1 runner runner   388160 Oct 14 06:37 libggml.so
-rw-r--r-- 1 runner runner  3733368 Oct 14 06:37 libllama-bench-impl.so
-rw-r--r-- 1 runner runner  2428384 Oct 14 06:37 libllama-cli-impl.so
-rw-r--r-- 1 runner runner 53555480 Oct 14 06:37 libllama-common.so
-rw-r--r-- 1 runner runner  1622744 Oct 14 06:37 libllama-perplexity-impl.so
-rw-r--r-- 1 runner runner  1011640 Oct 14 06:37 libllama-quantize-impl.so
-rw-r--r-- 1 runner runner 38391912 Oct 14 06:37 libllama.so

## 总体积
139M	dl
## 最大的 10 个文件
51.1 MB  dl/lib/libllama-common.so
36.6 MB  dl/lib/libllama.so
12.9 MB  dl/lib/libggml-opencl.so
8.9 MB  dl/lib/libc++_shared.so
7.4 MB  dl/lib/libggml-base.so
7.1 MB  dl/lib/libggml-hexagon.so
4.2 MB  dl/lib/libggml-cpu.so
3.6 MB  dl/lib/libllama-bench-impl.so
2.3 MB  dl/lib/libllama-cli-impl.so
1.5 MB  dl/lib/libllama-perplexity-impl.so

## ELF 架构校验
--- llama-bench ---
  Class:                             ELF64
  Type:                              DYN (Position-Independent Executable file)
  Machine:                           AArch64
--- llama-cli ---
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
OK   llama-cli -> libllama-cli-impl.so
MISS llama-cli -> libllama-server-impl.so
MISS llama-cli -> libmtmd.so
OK   llama-cli -> libllama-common.so
OK   llama-cli -> libllama.so
OK   llama-cli -> libggml.so
OK   llama-cli -> libggml-cpu.so
OK   llama-cli -> libggml-opencl.so
OK   llama-cli -> libggml-hexagon.so
OK   llama-cli -> libggml-base.so
MISS llama-cli -> libm.so
MISS llama-cli -> libdl.so
MISS llama-cli -> libc.so
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
