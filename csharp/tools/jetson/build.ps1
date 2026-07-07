<#
.SYNOPSIS
  Reproducible linux-arm64 CUDA build of ONNX Runtime via `docker buildx` (QEMU),
  then packs Microsoft.ML.OnnxRuntime.Gpu.Linux. Run from the Windows dev box.

.DESCRIPTION
  This is the SLOW, reproducible fallback path (emulated aarch64 — no GPU, cannot
  run CUDA). Prefer building natively on the Orin (build_on_device.sh). Use this to
  validate the build + packaging or for CI.

  Requires Docker Desktop with buildx + QEMU/binfmt for arm64 emulation:
    docker run --privileged --rm tonistiigi/binfmt --install arm64

.PARAMETER Config
  Build config: Release (default), RelWithDebInfo, Debug.

.PARAMETER CudaArch
  CUDA compute capability. Orin = 87 (default).

.PARAMETER UseTensorRT
  Also build the TensorRT EP.

.PARAMETER Version / ManagedVersion
  Package + managed-dependency version. Default: repo VERSION_NUMBER.

.PARAMETER OutDir
  Where buildx exports artifacts and the .nupkg is written.
  Default: csharp\tools\jetson\out

.PARAMETER SkipPack
  Only build/export native artifacts; do not pack.
#>
[CmdletBinding()]
param(
    [ValidateSet('Release', 'RelWithDebInfo', 'Debug')][string]$Config = 'Release',
    [string]$CudaArch = '87',
    [switch]$UseTensorRT,
    [string]$Version,
    [string]$ManagedVersion,
    [string]$OutDir,
    [switch]$SkipPack
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = (Resolve-Path (Join-Path $scriptDir '..\..\..')).Path

if (-not $Version) {
    $Version = (Get-Content (Join-Path $repoRoot 'VERSION_NUMBER') -Raw).Trim()
}
if (-not $ManagedVersion) { $ManagedVersion = $Version }
if (-not $OutDir)         { $OutDir = Join-Path $scriptDir 'out' }

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "docker not found. Install Docker Desktop with buildx."
}

Write-Host "Reproducible arm64 CUDA build via buildx (emulated). This is SLOW." -ForegroundColor Yellow
Write-Host "  config          : $Config"
Write-Host "  cuda arch       : $CudaArch"
Write-Host "  tensorrt        : $([bool]$UseTensorRT)"
Write-Host "  version         : $Version (managed dep $ManagedVersion)"
Write-Host "  out dir         : $OutDir"

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$dockerfile = Join-Path $scriptDir 'Dockerfile'
$useTrt = if ($UseTensorRT) { 'true' } else { 'false' }

$buildArgs = @(
    'buildx', 'build',
    '--platform', 'linux/arm64',
    '-f', $dockerfile,
    '--target', 'artifacts',
    '--build-arg', "BUILD_CONFIG=$Config",
    '--build-arg', "CUDA_ARCH=$CudaArch",
    '--build-arg', "USE_TENSORRT=$useTrt",
    '--output', "type=local,dest=$OutDir",
    $repoRoot
)

Write-Host "docker $($buildArgs -join ' ')" -ForegroundColor DarkGray
& docker @buildArgs
if ($LASTEXITCODE -ne 0) { throw "buildx build failed ($LASTEXITCODE)." }

Write-Host "Native artifacts exported to $OutDir" -ForegroundColor Green

if ($SkipPack) {
    Write-Host "SkipPack set; not packaging." -ForegroundColor Yellow
    return
}

& (Join-Path $scriptDir 'pack_gpu_linux_arm64.ps1') `
    -ArtifactsDir $OutDir -Version $Version -ManagedVersion $ManagedVersion -OutputDir $OutDir

& (Join-Path $scriptDir 'validate_package.ps1') `
    -NupkgPath (Join-Path $OutDir ("Microsoft.ML.OnnxRuntime.Gpu.Linux.{0}.nupkg" -f $Version))
