<#
.SYNOPSIS
  Validates a Microsoft.ML.OnnxRuntime.Gpu.Linux .nupkg layout without needing a GPU.

.DESCRIPTION
  Inspects the package to confirm the native library lands under
  runtimes/linux-arm64/native, which is what NuGet's RID resolver uses to feed
  libonnxruntime.so to the (architecture-neutral) managed package on a linux-arm64
  target. This is the host-side "test" of the packaging path.

.PARAMETER NupkgPath
  Path to the .nupkg to validate.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$NupkgPath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not (Test-Path $NupkgPath)) { throw "Package not found: $NupkgPath" }

Write-Host "Validating $NupkgPath" -ForegroundColor Cyan
$zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $NupkgPath))
try {
    $entries = $zip.Entries | ForEach-Object { $_.FullName }

    $native = $entries | Where-Object { $_ -like 'runtimes/linux-arm64/native/*' }
    Write-Host "Contents of runtimes/linux-arm64/native/:" -ForegroundColor Cyan
    if ($native) {
        $native | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host "  <none>" -ForegroundColor Red
    }

    $checks = @(
        @{ Name = 'core runtime (libonnxruntime.so)';        Pattern = 'runtimes/linux-arm64/native/libonnxruntime.so' },
        @{ Name = 'provider shared lib';                     Pattern = 'runtimes/linux-arm64/native/libonnxruntime_providers_shared.so' },
        @{ Name = 'CUDA provider (libonnxruntime_providers_cuda.so)'; Pattern = 'runtimes/linux-arm64/native/libonnxruntime_providers_cuda.so' }
    )

    $ok = $true
    Write-Host ""
    foreach ($c in $checks) {
        $hit = $entries | Where-Object { $_ -like ($c.Pattern + '*') } | Select-Object -First 1
        if ($hit) {
            Write-Host ("  [PASS] {0}: {1}" -f $c.Name, $hit) -ForegroundColor Green
        } else {
            Write-Host ("  [FAIL] {0}: missing ({1})" -f $c.Name, $c.Pattern) -ForegroundColor Red
            $ok = $false
        }
    }

    # nuspec dependency sanity
    $nuspecEntry = $zip.Entries | Where-Object { $_.FullName -like '*.nuspec' } | Select-Object -First 1
    if ($nuspecEntry) {
        $reader = New-Object System.IO.StreamReader($nuspecEntry.Open())
        try { $nuspecXml = $reader.ReadToEnd() } finally { $reader.Dispose() }
        if ($nuspecXml -match 'Microsoft\.ML\.OnnxRuntime\.Managed') {
            Write-Host "  [PASS] depends on Microsoft.ML.OnnxRuntime.Managed" -ForegroundColor Green
        } else {
            Write-Host "  [WARN] no Microsoft.ML.OnnxRuntime.Managed dependency found" -ForegroundColor Yellow
        }
    }

    Write-Host ""
    if ($ok) {
        Write-Host "Package layout looks correct for linux-arm64 RID resolution." -ForegroundColor Green
    } else {
        throw "Package validation FAILED - required native libraries missing."
    }
}
finally {
    $zip.Dispose()
}
