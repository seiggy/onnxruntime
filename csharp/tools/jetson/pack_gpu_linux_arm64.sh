#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.
#
# Packs the linux-arm64 CUDA native artifacts into a
# Microsoft.ML.OnnxRuntime.Gpu.Linux NuGet package (Linux / on-device).
#
# Requires the .NET SDK (arm64). Install on JetPack with:
#   curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 8.0
#   export PATH="$HOME/.dotnet:$PATH"
set -euo pipefail

ARTIFACTS_DIR=""
VERSION=""
MANAGED_VERSION=""
OUTPUT_DIR=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts-dir)   ARTIFACTS_DIR="$2"; shift 2 ;;
    --version)         VERSION="$2"; shift 2 ;;
    --managed-version) MANAGED_VERSION="$2"; shift 2 ;;
    --output-dir)      OUTPUT_DIR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$ARTIFACTS_DIR" ] || { echo "--artifacts-dir is required" >&2; exit 2; }
[ -n "$VERSION" ]       || VERSION="$(cat "$REPO_ROOT/VERSION_NUMBER")"
[ -n "$MANAGED_VERSION" ] || MANAGED_VERSION="$VERSION"
[ -n "$OUTPUT_DIR" ]    || OUTPUT_DIR="$ARTIFACTS_DIR"

NATIVE_DIR="$ARTIFACTS_DIR/runtimes/linux-arm64/native"
[ -d "$NATIVE_DIR" ] || { echo "Native dir not found: $NATIVE_DIR" >&2; exit 1; }

if ! command -v dotnet >/dev/null 2>&1; then
  echo "ERROR: 'dotnet' not found. Install the .NET SDK (see header of this script)." >&2
  exit 1
fi

# Build <files> nodes from the actual .so files present.
FILE_NODES=""
shopt -s nullglob
for f in "$NATIVE_DIR"/*.so*; do
  base="$(basename "$f")"
  FILE_NODES+="    <file src=\"runtimes/linux-arm64/native/$base\" target=\"runtimes/linux-arm64/native\" />"$'\n'
done
shopt -u nullglob
[ -n "$FILE_NODES" ] || { echo "No .so files under $NATIVE_DIR" >&2; exit 1; }

NUSPEC="$ARTIFACTS_DIR/Microsoft.ML.OnnxRuntime.Gpu.Linux.nuspec"
cat > "$NUSPEC" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2013/05/nuspec.xsd">
  <metadata>
    <id>Microsoft.ML.OnnxRuntime.Gpu.Linux</id>
    <version>$VERSION</version>
    <authors>Microsoft</authors>
    <owners>Microsoft</owners>
    <requireLicenseAcceptance>false</requireLicenseAcceptance>
    <license type="expression">MIT</license>
    <projectUrl>https://github.com/microsoft/onnxruntime</projectUrl>
    <description>Linux arm64 (aarch64) native CUDA build of ONNX Runtime for NVIDIA Jetson Orin (sm_87, JetPack 6.2 / CUDA 12.6). Locally built. Pairs with Microsoft.ML.OnnxRuntime.Managed. The target device must provide the JetPack CUDA/cuDNN/TensorRT runtime libraries.</description>
    <tags>ONNX ONNXRuntime CUDA TensorRT Jetson Orin arm64 aarch64 machinelearning</tags>
    <dependencies>
      <group targetFramework="netstandard2.0">
        <dependency id="Microsoft.ML.OnnxRuntime.Managed" version="$MANAGED_VERSION" />
      </group>
    </dependencies>
  </metadata>
  <files>
$FILE_NODES  </files>
</package>
EOF

echo "Wrote nuspec: $NUSPEC"
mkdir -p "$OUTPUT_DIR"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/_pack.csproj" <<EOF
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>netstandard2.0</TargetFramework>
    <IncludeBuildOutput>false</IncludeBuildOutput>
    <EnableDefaultItems>false</EnableDefaultItems>
    <NuspecFile>$NUSPEC</NuspecFile>
    <NuspecBasePath>$ARTIFACTS_DIR</NuspecBasePath>
  </PropertyGroup>
</Project>
EOF

dotnet pack "$TMP/_pack.csproj" -o "$OUTPUT_DIR" --nologo

NUPKG="$OUTPUT_DIR/Microsoft.ML.OnnxRuntime.Gpu.Linux.$VERSION.nupkg"
if [ -f "$NUPKG" ]; then
  echo "Created: $NUPKG"
else
  echo "WARNING: expected package not found at $NUPKG; check $OUTPUT_DIR" >&2
fi
