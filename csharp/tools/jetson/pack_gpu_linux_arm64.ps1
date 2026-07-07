<#
.SYNOPSIS
  Packs the linux-arm64 CUDA native artifacts (produced by build_ort_arm64.sh /
  the buildx Dockerfile) into a Microsoft.ML.OnnxRuntime.Gpu.Linux NuGet package.

.DESCRIPTION
  Generates a .nuspec that places the built .so files under
  runtimes/linux-arm64/native and depends on Microsoft.ML.OnnxRuntime.Managed,
  then packs it with nuget.exe (if on PATH) or `dotnet pack` as a fallback.

  The resulting package is a drop-in linux-arm64 counterpart to the official
  x64-only Microsoft.ML.OnnxRuntime.Gpu.Linux package. Push it to a private feed
  (or reference the folder as a local source) alongside Microsoft.ML.OnnxRuntime.Managed.

.PARAMETER ArtifactsDir
  Directory containing runtimes/linux-arm64/native/*.so (buildx --output dest, or the
  ARTIFACTS_DIR from an on-device build).

.PARAMETER Version
  Package version. Defaults to the repo VERSION_NUMBER.

.PARAMETER ManagedVersion
  Version of the Microsoft.ML.OnnxRuntime.Managed dependency. Defaults to -Version.
  MUST be ABI-compatible with the native build (ideally packed from the same source).

.PARAMETER OutputDir
  Where to write the .nupkg. Defaults to ArtifactsDir.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ArtifactsDir,
    [string]$Version,
    [string]$ManagedVersion,
    [string]$OutputDir
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = (Resolve-Path (Join-Path $scriptDir '..\..\..')).Path

if (-not $Version) {
    $Version = (Get-Content (Join-Path $repoRoot 'VERSION_NUMBER') -Raw).Trim()
}
if (-not $ManagedVersion) { $ManagedVersion = $Version }
if (-not $OutputDir)      { $OutputDir = $ArtifactsDir }

$ArtifactsDir = (Resolve-Path $ArtifactsDir).Path
$nativeDir = Join-Path $ArtifactsDir 'runtimes\linux-arm64\native'
if (-not (Test-Path $nativeDir)) {
    throw "Native directory not found: $nativeDir. Run the arm64 build first."
}

$soFiles = Get-ChildItem -Path $nativeDir -Filter '*.so*' -File | Sort-Object Name
if ($soFiles.Count -eq 0) {
    throw "No .so files found under $nativeDir."
}

Write-Host "Packaging Microsoft.ML.OnnxRuntime.Gpu.Linux $Version (arm64)" -ForegroundColor Cyan
Write-Host "  managed dependency version : $ManagedVersion"
Write-Host "  native files:"
$soFiles | ForEach-Object { Write-Host ("    runtimes/linux-arm64/native/{0}" -f $_.Name) }

# Build <files> entries (forward slashes; relative to basePath = ArtifactsDir).
$fileNodes = ($soFiles | ForEach-Object {
    '    <file src="runtimes/linux-arm64/native/{0}" target="runtimes/linux-arm64/native" />' -f $_.Name
}) -join "`n"

$nuspec = @"
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2013/05/nuspec.xsd">
  <metadata>
    <id>Microsoft.ML.OnnxRuntime.Gpu.Linux</id>
    <version>$Version</version>
    <authors>Microsoft</authors>
    <owners>Microsoft</owners>
    <requireLicenseAcceptance>false</requireLicenseAcceptance>
    <license type="expression">MIT</license>
    <projectUrl>https://github.com/microsoft/onnxruntime</projectUrl>
    <description>Linux arm64 (aarch64) native CUDA build of ONNX Runtime for NVIDIA Jetson Orin (sm_87, JetPack 6.2 / CUDA 12.6). Locally built. Pairs with Microsoft.ML.OnnxRuntime.Managed. The target device must provide the JetPack CUDA/cuDNN/TensorRT runtime libraries.</description>
    <tags>ONNX ONNXRuntime CUDA TensorRT Jetson Orin arm64 aarch64 machinelearning</tags>
    <dependencies>
      <group targetFramework="netstandard2.0">
        <dependency id="Microsoft.ML.OnnxRuntime.Managed" version="$ManagedVersion" />
      </group>
    </dependencies>
  </metadata>
  <files>
$fileNodes
  </files>
</package>
"@

$nuspecPath = Join-Path $ArtifactsDir 'Microsoft.ML.OnnxRuntime.Gpu.Linux.nuspec'
Set-Content -Path $nuspecPath -Value $nuspec -Encoding UTF8
Write-Host "Wrote nuspec: $nuspecPath"

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$nugetExe = Get-Command nuget -ErrorAction SilentlyContinue
if ($nugetExe) {
    Write-Host "Packing with nuget.exe ..." -ForegroundColor Cyan
    & $nugetExe.Source pack $nuspecPath -BasePath $ArtifactsDir -OutputDirectory $OutputDir -NoDefaultExcludes
    if ($LASTEXITCODE -ne 0) { throw "nuget pack failed ($LASTEXITCODE)." }
}
else {
    Write-Host "nuget.exe not found; packing with 'dotnet pack' ..." -ForegroundColor Cyan
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) { throw "Neither nuget.exe nor dotnet is available to pack the package." }

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ortpack_" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $proj = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>netstandard2.0</TargetFramework>
    <IncludeBuildOutput>false</IncludeBuildOutput>
    <EnableDefaultItems>false</EnableDefaultItems>
    <NuspecFile>$nuspecPath</NuspecFile>
    <NuspecBasePath>$ArtifactsDir</NuspecBasePath>
  </PropertyGroup>
</Project>
"@
        $projPath = Join-Path $tmp '_pack.csproj'
        Set-Content -Path $projPath -Value $proj -Encoding UTF8
        & $dotnet.Source pack $projPath -o $OutputDir --nologo
        if ($LASTEXITCODE -ne 0) { throw "dotnet pack failed ($LASTEXITCODE)." }
    }
    finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

$nupkg = Join-Path $OutputDir ("Microsoft.ML.OnnxRuntime.Gpu.Linux.{0}.nupkg" -f $Version)
if (Test-Path $nupkg) {
    Write-Host "Created: $nupkg" -ForegroundColor Green
}
else {
    Write-Warning "Pack completed but expected package not found at $nupkg. Check $OutputDir."
}
