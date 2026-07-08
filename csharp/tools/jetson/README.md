# ONNX Runtime — linux-arm64 + CUDA (NVIDIA Jetson Orin) for .NET

This folder scaffolds a build + NuGet packaging flow that produces the **missing
linux-arm64 CUDA native package** so the (architecture-neutral) managed package
`Microsoft.ML.OnnxRuntime.Managed` works on an **NVIDIA Jetson Orin** (Orin Nano,
sm_87, JetPack 6.2 / L4T r36.4 / CUDA 12.6 / cuDNN 9 / TensorRT 10.3).

## Why this is needed (and what it is *not*)

The C# package splits into two NuGets:

* **`Microsoft.ML.OnnxRuntime.Managed`** — pure managed IL, **architecture-neutral**.
  It already P/Invokes `libonnxruntime.so` on *any* arch. **No changes are needed here**
  for arm64; the managed layer is not the gap.
* **`Microsoft.ML.OnnxRuntime.Gpu.Linux`** — the *native* package. Upstream it only ships
  `runtimes/linux-x64/native/`; **there is no `runtimes/linux-arm64/native/` payload**
  because no CI leg builds a CUDA-enabled `onnxruntime-linux-aarch64` artifact.

So the real work is **native build + packaging**, not the `.csproj`. This scaffold builds
the aarch64 CUDA `.so` files and packs them into a drop-in `Microsoft.ML.OnnxRuntime.Gpu.Linux`
package with the `linux-arm64` RID, which NuGet's runtime resolver then feeds to the managed
package automatically.

> The upstream packaging script (`tools/nuget/generate_nuspec_for_native_nuget.py`) emits
> Windows-style `runtimes\linux-...` targets and is designed to run on a Windows ADO host
> assembling multi-job artifacts. It does not run cleanly on a Linux build host, so this
> scaffold generates a small purpose-built nuspec instead.

## Compilation: which machine?

You do **not** need an NVIDIA GPU to *compile* — `nvcc` builds device code without a GPU
(a GPU is only needed to *run* kernels). The binaries must be **aarch64**, so:

| Path | Speed | Notes |
|---|---|---|
| **Native on the Orin** *(recommended)* | slow CPU, 16 GB RAM | simplest correct path; only place you can validate CUDA inference. Use `build_on_device.sh`. |
| **buildx QEMU on a fast x86 box** | slowest (10–20× CPU) | reproducible/CI fallback; **cannot run CUDA** (no GPU in emulation). Use `build.ps1`. |
| **Cross-compile on x86** | fastest | heavy setup (L4T sysroot + `cuda-cross-aarch64`); only worth it for frequent rebuilds. |

## Files

| File | Runs on | Purpose |
|---|---|---|
| `build_ort_arm64.sh`     | Orin **or** container | Core native build (CUDA, optional TensorRT) + stages artifacts. Shared by both paths. |
| `build_on_device.sh`     | Orin | One-shot: build + pack on the device. |
| `pack_gpu_linux_arm64.sh`| Orin / Linux | Generate nuspec + `dotnet pack`. |
| `Dockerfile` / `Dockerfile.dockerignore` | x86 host | buildx (`linux/arm64`) reproducible build. |
| `build.ps1`              | Windows host | Drives buildx, exports artifacts, packs, validates. |
| `pack_gpu_linux_arm64.ps1` | Windows host | Generate nuspec + pack (nuget.exe or `dotnet pack`). |
| `validate_package.ps1`   | any | Inspect the `.nupkg` layout (no GPU needed). |

## Recommended: build natively on the Orin

```bash
# On the Orin, inside your onnxruntime checkout:
# (16 GB tip: keep --parallel low; ensure swap/zram is enabled)
csharp/tools/jetson/build_on_device.sh --parallel 4
# add --tensorrt to also build the TensorRT EP
# add --managed-version 1.28.0 to override the managed dependency version
```

Outputs to `csharp/tools/jetson/out/`:
`Microsoft.ML.OnnxRuntime.Gpu.Linux.<version>.nupkg` plus
`runtimes/linux-arm64/native/*.so`.

Requires the .NET SDK (arm64) on the Orin to pack:
```bash
curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 8.0
export PATH="$HOME/.dotnet:$PATH"
```

## Fallback: reproducible buildx on the Windows box (slow)

```powershell
# One-time: enable arm64 emulation
docker run --privileged --rm tonistiigi/binfmt --install arm64

# Build (emulated aarch64) + pack + validate
csharp\tools\jetson\build.ps1
# -UseTensorRT, -CudaArch 87, -Config Release, -SkipPack, -OutDir ... all supported
```

Then validate the package layout (works anywhere, no GPU):
```powershell
csharp\tools\jetson\validate_package.ps1 -NupkgPath csharp\tools\jetson\out\Microsoft.ML.OnnxRuntime.Gpu.Linux.<version>.nupkg
```

## Managed package must match (ABI)

The native `.so` and the managed DLL share one C API surface, so **versions must match**.
If you build native from `main` (currently `1.28.0`), pack a matching managed package from
the **same** source rather than referencing an old released one:

```powershell
dotnet pack csharp\src\Microsoft.ML.OnnxRuntime\Microsoft.ML.OnnxRuntime.csproj `
  -c Release -p:IncludeMobileTargets=false -o csharp\tools\jetson\out
# -> Microsoft.ML.OnnxRuntime.Managed.<version>.nupkg  (netstandard2.0;net8.0 only)
```

`-p:IncludeMobileTargets=false` avoids requiring the MAUI/Android/iOS workloads.

## Consuming from your .NET app (on the Orin)

Add a local feed and reference both packages:

```xml
<!-- nuget.config -->
<configuration>
  <packageSources>
    <add key="local-ort" value="/path/to/csharp/tools/jetson/out" />
  </packageSources>
</configuration>
```

```xml
<!-- YourApp.csproj  (publish with -r linux-arm64) -->
<ItemGroup>
  <PackageReference Include="Microsoft.ML.OnnxRuntime.Managed" Version="1.28.0" />
  <PackageReference Include="Microsoft.ML.OnnxRuntime.Gpu.Linux" Version="1.28.0" />
</ItemGroup>
```

```csharp
using var opts = SessionOptions.MakeSessionOptionWithCudaProvider(0);
using var session = new InferenceSession("model.onnx", opts);
```

## Validate end-to-end on the Orin (sample smoke test)

`sample/` contains **`OrtJetsonCudaSample`** — a standalone console app that *consumes the
NuGet packages* (managed + the arm64 `Gpu.Linux` package) exactly like a customer app, then
loads a model and runs it on the **CUDA** provider. Unlike
`csharp/test/Microsoft.ML.OnnxRuntime.Tests.NetCoreApp` (which builds against the in-tree
native binaries and is not package-based), this validates the *packaged* linux-arm64 CUDA
path via NuGet RID resolution.

```bash
# On the Orin, after build_on_device.sh has populated ../out with the packages:
cd csharp/tools/jetson/sample
dotnet run -c Release -r linux-arm64 -p:OrtVersion=$(cat ../../../../VERSION_NUMBER)
```

It prints the available providers, confirms `CUDAExecutionProvider`, runs `mul_1.onnx`
(shipped alongside), and returns **exit code 0 on success / 1 on failure** — so it doubles
as a CI/bring-up gate. Options:

```bash
dotnet run -c Release -r linux-arm64 -- --cpu            # force CPU fallback
dotnet run -c Release -r linux-arm64 -- path/model.onnx  # use your own float model
```

The `sample/nuget.config` adds `..\out` as a local feed so the locally built packages
resolve. Set `-p:OrtVersion=` to match the version you packed.

## Troubleshooting

**Build fails ~75% with `gmake ... Error 2` during CUDA compile (e.g. after a
`flash_fwd_*` / `flash_attention` object).** This is almost always **out-of-memory**,
not a code error — the flash / memory-efficient / lean attention kernels are the heaviest
`.cu` files and several parallel `nvcc` processes exhaust the 16 GB Orin. Confirm with:

```bash
dmesg | grep -iE "killed process|out of memory" | tail
```

Fix — rebuild with the fused-attention kernels disabled and lower parallelism (cached
objects are reused, so it resumes near where it stopped):

```bash
csharp/tools/jetson/build_on_device.sh --low-memory      # = disable fused attention + --parallel 2
```

Attention ops then fall back to unfused CUDA kernels (fine for typical Jetson inference).
To keep flash attention instead, add swap and drop to `--parallel 1`. You can also pass
extra CMake defines via `EXTRA_CMAKE_DEFINES` to `build_ort_arm64.sh`.

## Important caveats

* **Runtime deps come from JetPack.** The packaged `.so` files link against the device's
  CUDA/cuDNN/TensorRT. The Orin must run the matching JetPack (6.2 / CUDA 12.6).
* **Emulation cannot run CUDA.** The buildx path validates *build + packaging* only; real
  inference must be verified on the physical Orin.
* **sm_87** is the Orin compute capability (`cmake/external/cuda_configuration.cmake`).
  For a smaller/faster build this scaffold defaults to a single arch (`CUDA_ARCH=87`).
* This is a **local/private** packaging aid, not an official ORT release artifact.
