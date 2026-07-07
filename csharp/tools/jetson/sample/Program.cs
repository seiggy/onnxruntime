// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// ONNX Runtime CUDA smoke test for NVIDIA Jetson Orin (linux-arm64).
//
// Verifies that:
//   1. The arm64 native library loads (via the Gpu.Linux package's
//      runtimes/linux-arm64/native payload),
//   2. The CUDA execution provider is available and can be appended,
//   3. A model loads and runs to completion with CUDA enabled.
//
// Exit code 0 on success, 1 on failure — usable as a CI/bring-up gate.

using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

static int Fail(string message, Exception? ex = null)
{
    Console.Error.WriteLine($"[FAIL] {message}");
    if (ex is not null)
    {
        Console.Error.WriteLine(ex);
    }
    return 1;
}

bool forceCpu = false;
string? modelArg = null;
foreach (var a in args)
{
    if (a is "--cpu") forceCpu = true;
    else if (!a.StartsWith("--")) modelArg = a;
}

// 1. Native library load + provider discovery.
string[] providers;
try
{
    providers = OrtEnv.Instance().GetAvailableProviders();
}
catch (Exception ex)
{
    return Fail("Could not load the ONNX Runtime native library. On the Orin, ensure "
             + "JetPack 6.2 (CUDA 12.6) runtime libs are present and the linux-arm64 "
             + "native package was restored.", ex);
}

Console.WriteLine("ONNX Runtime version : " + typeof(InferenceSession).Assembly.GetName().Version);
Console.WriteLine("Available providers  : " + string.Join(", ", providers));

bool cudaAvailable = Array.IndexOf(providers, "CUDAExecutionProvider") >= 0;
bool useCuda = cudaAvailable && !forceCpu;

if (forceCpu)
{
    Console.WriteLine("Requested provider   : CPU (--cpu)");
}
else if (!cudaAvailable)
{
    return Fail("CUDAExecutionProvider is NOT available. The loaded native library was not "
              + "built with CUDA, or libonnxruntime_providers_cuda.so is missing from "
              + "runtimes/linux-arm64/native. Re-run the arm64 CUDA build.");
}
else
{
    Console.WriteLine("Requested provider   : CUDA (device 0)");
}

// 2. Resolve the model.
string modelPath = modelArg
    ?? Path.Combine(AppContext.BaseDirectory, "mul_1.onnx");
if (!File.Exists(modelPath))
{
    return Fail($"Model not found: {modelPath}");
}
Console.WriteLine("Model                : " + modelPath);

// 3. Create session (CUDA or CPU) and run.
try
{
    using var options = new SessionOptions();
    options.GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL;
    if (useCuda)
    {
        options.AppendExecutionProvider_CUDA(0);
    }

    using var session = new InferenceSession(modelPath, options);

    var inputs = new List<NamedOnnxValue>();
    foreach (var kv in session.InputMetadata)
    {
        var meta = kv.Value;
        if (meta.OnnxValueType != OnnxValueType.ONNX_TYPE_TENSOR ||
            meta.ElementDataType != TensorElementType.Float)
        {
            return Fail($"Sample only handles float tensor inputs; '{kv.Key}' is "
                      + $"{meta.OnnxValueType}/{meta.ElementDataType}. Pass a float model.");
        }

        // Replace unknown/symbolic dims (-1) with 1 to form a concrete shape.
        int[] shape = meta.Dimensions.Select(d => d < 0 ? 1 : d).ToArray();
        int count = shape.Aggregate(1, (acc, d) => acc * d);
        var data = new float[count];
        for (int i = 0; i < count; i++) data[i] = i + 1.0f;

        var tensor = new DenseTensor<float>(data, shape);
        inputs.Add(NamedOnnxValue.CreateFromTensor(kv.Key, tensor));
        Console.WriteLine($"Input '{kv.Key}'      : float[{string.Join(",", shape)}]");
    }

    using var results = session.Run(inputs);

    foreach (var r in results)
    {
        var t = r.AsTensor<float>();
        var preview = string.Join(", ", t.Take(Math.Min(6, (int)t.Length)));
        Console.WriteLine($"Output '{r.Name}'     : float[{string.Join(",", t.Dimensions.ToArray())}] => [{preview}{(t.Length > 6 ? ", ..." : "")}]");
    }

    Console.WriteLine();
    Console.WriteLine($"[PASS] Inference completed using {(useCuda ? "CUDA" : "CPU")} execution provider.");
    return 0;
}
catch (Exception ex)
{
    return Fail("Inference failed.", ex);
}
