# syntax=docker/dockerfile:1.7
#
# Cross-build ONNX Runtime (native, shared lib) for linux-arm64 with CUDA (+ optional
# TensorRT) targeting NVIDIA Jetson Orin (sm_87 / JetPack 6.2, L4T r36.4).
#
# Driven by build.ps1 via `docker buildx build --platform linux/arm64` (QEMU emulation).
# Produces ONLY the native artifacts, laid out for NuGet packaging.
#
# NOTE: Emulated CUDA builds are SLOW (potentially hours) and cannot RUN CUDA kernels
#       (no GPU in emulation). Prefer building natively on the Orin. This path exists
#       for a reproducible / CI-style build. See README.md.
#
# Base image: JetPack 6.2 (r36.4.x) bundles CUDA 12.6, cuDNN 9, TensorRT 10.3.
ARG BASE_IMAGE=nvcr.io/nvidia/l4t-jetpack:r36.4.0

FROM ${BASE_IMAGE} AS build

# Build configuration (overridable via --build-arg)
ARG BUILD_CONFIG=Release
ARG CUDA_ARCH=87
ARG USE_TENSORRT=false

ENV DEBIAN_FRONTEND=noninteractive \
    CUDA_HOME=/usr/local/cuda \
    PATH=/usr/local/cuda/bin:${PATH} \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH} \
    BUILD_CONFIG=${BUILD_CONFIG} \
    CUDA_ARCH=${CUDA_ARCH} \
    USE_TENSORRT=${USE_TENSORRT} \
    ARTIFACTS_DIR=/artifacts

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        git \
        wget \
        curl \
        ca-certificates \
        ninja-build \
        python3 \
        python3-dev \
        python3-pip \
        libopenblas-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# ONNX Runtime requires a newer CMake than the l4t (Ubuntu 22.04) base ships.
# The pip wheel provides an aarch64 build of a recent CMake.
RUN python3 -m pip install --no-cache-dir --upgrade pip && \
    python3 -m pip install --no-cache-dir "cmake>=3.28,<4.0" ninja packaging setuptools wheel

WORKDIR /src
COPY . /src

RUN chmod +x /src/csharp/tools/jetson/build_ort_arm64.sh && \
    /src/csharp/tools/jetson/build_ort_arm64.sh

# ---------------------------------------------------------------------------
# Export-only stage. `--output type=local` on this target copies just the
# packaging-ready native artifacts to the host (no full image is produced).
# ---------------------------------------------------------------------------
FROM scratch AS artifacts
COPY --from=build /artifacts/ /
