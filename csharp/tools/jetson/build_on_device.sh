#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.
#
# Convenience wrapper to build AND package on the Jetson Orin device itself
# (the recommended, fastest-to-correct path).
#
# Usage (from anywhere in the repo checkout on the Orin):
#   csharp/tools/jetson/build_on_device.sh [--tensorrt] [--parallel N] [--low-memory] [--managed-version X]
#
# Memory guidance for the 16 GB Orin Nano:
#   The flash/memory-efficient/lean attention CUDA kernels are the heaviest translation
#   units and the usual cause of OOM ("gmake ... Error 2") during the CUDA compile.
#   If you hit OOM, use --low-memory (disables those kernels + sets --parallel 2) and
#   ensure swap/zram is enabled:  sudo systemctl enable --now nvzramconfig  (JetPack)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

USE_TENSORRT=false
PARALLEL="${PARALLEL:-4}"          # conservative default for 16 GB
DISABLE_FUSED_ATTENTION="${DISABLE_FUSED_ATTENTION:-false}"
MANAGED_VERSION=""
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$REPO_ROOT/csharp/tools/jetson/out}"

while [ $# -gt 0 ]; do
  case "$1" in
    --tensorrt)         USE_TENSORRT=true; shift ;;
    --parallel)         PARALLEL="$2"; shift 2 ;;
    --low-memory)       DISABLE_FUSED_ATTENTION=true; PARALLEL=2; shift ;;
    --managed-version)  MANAGED_VERSION="$2"; shift 2 ;;
    --artifacts-dir)    ARTIFACTS_DIR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

VERSION="$(cat "$REPO_ROOT/VERSION_NUMBER")"
[ -n "$MANAGED_VERSION" ] || MANAGED_VERSION="$VERSION"

echo ">> Building native ONNX Runtime (arm64 + CUDA) on device ..."
BUILD_CONFIG="${BUILD_CONFIG:-Release}" \
CUDA_ARCH="${CUDA_ARCH:-87}" \
USE_TENSORRT="$USE_TENSORRT" \
PARALLEL="$PARALLEL" \
DISABLE_FUSED_ATTENTION="$DISABLE_FUSED_ATTENTION" \
ARTIFACTS_DIR="$ARTIFACTS_DIR" \
  "$SCRIPT_DIR/build_ort_arm64.sh"

echo ">> Packing Microsoft.ML.OnnxRuntime.Gpu.Linux ($VERSION) ..."
"$SCRIPT_DIR/pack_gpu_linux_arm64.sh" \
  --artifacts-dir "$ARTIFACTS_DIR" \
  --version "$VERSION" \
  --managed-version "$MANAGED_VERSION" \
  --output-dir "$ARTIFACTS_DIR"

echo ">> Done. Package(s) in: $ARTIFACTS_DIR"
