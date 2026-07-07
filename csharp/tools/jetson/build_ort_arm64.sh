#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.
#
# Builds ONNX Runtime (native shared library) for linux-arm64 with CUDA and
# optional TensorRT, targeting NVIDIA Jetson Orin (sm_87).
#
# Runs in two modes with the SAME logic:
#   * On the Orin device directly (fast, recommended).
#   * Inside the linux/arm64 buildx container (Dockerfile) for a reproducible build.
#
# Environment overrides:
#   BUILD_CONFIG    Release (default) | RelWithDebInfo | Debug
#   CUDA_ARCH       CUDA compute capability. Orin = 87 (default). Multi: "87;72"
#   USE_TENSORRT    "true" to enable the TensorRT EP (default "false")
#   CUDA_HOME       default /usr/local/cuda
#   CUDNN_HOME      default /usr/lib/aarch64-linux-gnu (JetPack multiarch layout)
#   TENSORRT_HOME   default /usr/lib/aarch64-linux-gnu
#   ARTIFACTS_DIR   where to stage packaging-ready output (default /artifacts)
#   PARALLEL        override build parallelism (default: auto)
set -euo pipefail

BUILD_CONFIG="${BUILD_CONFIG:-Release}"
CUDA_ARCH="${CUDA_ARCH:-87}"
USE_TENSORRT="${USE_TENSORRT:-false}"
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
CUDNN_HOME="${CUDNN_HOME:-/usr/lib/aarch64-linux-gnu}"
TENSORRT_HOME="${TENSORRT_HOME:-/usr/lib/aarch64-linux-gnu}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-/artifacts}"

# Repo root = three levels up from csharp/tools/jetson
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$SRC_DIR"

echo "=========================================================="
echo " ONNX Runtime arm64 CUDA build"
echo "   source          : $SRC_DIR"
echo "   version         : $(cat "$SRC_DIR/VERSION_NUMBER")"
echo "   config          : $BUILD_CONFIG"
echo "   cuda arch       : $CUDA_ARCH"
echo "   cuda home       : $CUDA_HOME"
echo "   cudnn home      : $CUDNN_HOME"
echo "   tensorrt        : $USE_TENSORRT (home=$TENSORRT_HOME)"
echo "   host arch       : $(uname -m)"
echo "   artifacts dir   : $ARTIFACTS_DIR"
echo "=========================================================="

if [ "$(uname -m)" != "aarch64" ]; then
  echo "WARNING: host arch is $(uname -m), not aarch64. Under QEMU emulation this"
  echo "         CUDA build will be very slow and cannot execute CUDA kernels."
fi

EXTRA_ARGS=()
if [ "$USE_TENSORRT" = "true" ]; then
  EXTRA_ARGS+=( --use_tensorrt --tensorrt_home "$TENSORRT_HOME" )
fi

PARALLEL_ARGS=( --parallel )
if [ -n "${PARALLEL:-}" ]; then
  PARALLEL_ARGS=( --parallel "$PARALLEL" )
fi

./build.sh \
  --config "$BUILD_CONFIG" \
  --build_shared_lib \
  "${PARALLEL_ARGS[@]}" \
  --skip_tests \
  --allow_running_as_root \
  --use_cuda \
  --cuda_home "$CUDA_HOME" \
  --cudnn_home "$CUDNN_HOME" \
  "${EXTRA_ARGS[@]}" \
  --cmake_extra_defines \
    CMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
    onnxruntime_BUILD_UNIT_TESTS=OFF

# build.sh writes to build/Linux/<config>
OUT_DIR="$SRC_DIR/build/Linux/$BUILD_CONFIG"
NATIVE_DIR="$ARTIFACTS_DIR/runtimes/linux-arm64/native"
INCLUDE_DIR="$ARTIFACTS_DIR/build/native/include"
mkdir -p "$NATIVE_DIR" "$INCLUDE_DIR"

echo "Collecting native artifacts from $OUT_DIR ..."

# Core runtime (preserve the SONAME symlink + versioned file so provider libs,
# which have RPATH=$ORIGIN, can resolve libonnxruntime.so.<ver> at load time).
cp -av "$OUT_DIR/libonnxruntime.so"* "$NATIVE_DIR/"

# Provider shared libs (present for CUDA / TensorRT builds).
for so in libonnxruntime_providers_shared.so libonnxruntime_providers_cuda.so; do
  if [ -f "$OUT_DIR/$so" ]; then
    cp -av "$OUT_DIR/$so" "$NATIVE_DIR/"
  fi
done
if [ "$USE_TENSORRT" = "true" ] && [ -f "$OUT_DIR/libonnxruntime_providers_tensorrt.so" ]; then
  cp -av "$OUT_DIR/libonnxruntime_providers_tensorrt.so" "$NATIVE_DIR/"
fi

# C/C++ headers (handy for native consumers; harmless for the managed package).
cp -av "$SRC_DIR/include/onnxruntime/core/session/"onnxruntime_*.h "$INCLUDE_DIR/" 2>/dev/null || true

# Provenance manifest.
{
  echo "onnxruntime_version=$(cat "$SRC_DIR/VERSION_NUMBER")"
  echo "build_config=$BUILD_CONFIG"
  echo "cuda_arch=$CUDA_ARCH"
  echo "use_tensorrt=$USE_TENSORRT"
  echo "host_arch=$(uname -m)"
  echo "cuda_home=$CUDA_HOME"
  echo "cudnn_home=$CUDNN_HOME"
  echo "built_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$ARTIFACTS_DIR/build_info.txt"

echo "=========================================================="
echo " Native artifacts staged under: $NATIVE_DIR"
ls -la "$NATIVE_DIR"
echo "=========================================================="
