#!/usr/bin/env bash
# 把 cmake --install 的产物整理成 Android 工程可直接使用的 jniLibs 结构
#
# 用法: bash make_jniLibs.sh <pkg_dir> <out_dir> <htp_arch: v73|all>
set -euo pipefail

PKG_DIR="${1:?用法: make_jniLibs.sh <pkg_dir> <out_dir> <v73|all>}"
OUT_DIR="${2:?用法: make_jniLibs.sh <pkg_dir> <out_dir> <v73|all>}"
HTP_ARCH="${3:-all}"

LIB_DIR="${PKG_DIR}/lib"
INC_DIR="${PKG_DIR}/include"

if [ ! -d "${LIB_DIR}" ]; then
  echo "::error::没找到 ${LIB_DIR}，cmake install 可能失败了"
  exit 1
fi

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}/jniLibs/arm64-v8a"

# ---- 1. 拷贝主库 ----
cp -a "${LIB_DIR}"/*.so "${OUT_DIR}/jniLibs/arm64-v8a/" 2>/dev/null || true

# ---- 2. 按架构过滤 HTP 固件库 ----
if [ "${HTP_ARCH}" = "v73" ]; then
  echo "只保留 v73 固件库，删除其它架构"
  find "${OUT_DIR}/jniLibs/arm64-v8a" -name 'libggml-htp-v*.so' \
    ! -name 'libggml-htp-v73.so' -delete
fi

# ---- 3. 补上 libc++_shared.so ----
# NDK 编译出来的 .so 运行时依赖它，手动放 jniLibs 时必须一起打包，
# 否则 APK 安装后会直接 dlopen 失败。
if ! [ -f "${OUT_DIR}/jniLibs/arm64-v8a/libc++_shared.so" ]; then
  NDK_ROOT="${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-}}"
  if [ -z "${NDK_ROOT}" ]; then
    NDK_ROOT="$(ls -d /opt/android-ndk-r* 2>/dev/null | head -1 || true)"
  fi
  CXX_SHARED="$(find "${NDK_ROOT}" -path '*arm64-v8a*' -name 'libc++_shared.so' 2>/dev/null | head -1 || true)"
  if [ -n "${CXX_SHARED}" ]; then
    cp -a "${CXX_SHARED}" "${OUT_DIR}/jniLibs/arm64-v8a/"
    echo "已补齐 libc++_shared.so"
  else
    echo "::warning::没找到 libc++_shared.so，请手动从 NDK 里补到 jniLibs/arm64-v8a/"
  fi
fi

# ---- 4. 拷贝头文件 ----
if [ -d "${INC_DIR}" ]; then
  mkdir -p "${OUT_DIR}/include"
  cp -a "${INC_DIR}/." "${OUT_DIR}/include/"
fi

# ---- 5. 顺手带上命令行工具，方便 adb 上先验证 ----
if [ -d "${PKG_DIR}/bin" ]; then
  mkdir -p "${OUT_DIR}/bin"
  cp -a "${PKG_DIR}/bin/." "${OUT_DIR}/bin/" 2>/dev/null || true
fi

# ---- 6. 去掉调试符号，减小 APK 体积 ----
if command -v llvm-strip >/dev/null 2>&1; then
  find "${OUT_DIR}/jniLibs/arm64-v8a" -name '*.so' -exec llvm-strip --strip-unneeded {} \; 2>/dev/null || true
elif command -v "${TARGET_STRIP:-aarch64-linux-android-strip}" >/dev/null 2>&1; then
  find "${OUT_DIR}/jniLibs/arm64-v8a" -name '*.so' -exec "${TARGET_STRIP}" --strip-unneeded {} \; 2>/dev/null || true
fi

echo "整理完成 -> ${OUT_DIR}"
