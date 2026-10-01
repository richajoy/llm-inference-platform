# Ops:Byte Analysis Framework

## Introduction

The ops:byte ratio (arithmetic intensity) is the single most important metric for understanding LLM inference performance. It determines whether a workload is **compute-bound** or **memory-bandwidth-bound**, which in turn dictates GPU selection, batching strategy, quantization decisions, and the entire serving architecture.

This document provides the theoretical foundation used throughout this platform.

## The Arithmetic Intensity Formula

```
Arithmetic Intensity (AI) = FLOPs performed / Bytes accessed from memory
                          = ops : byte ratio
```

- **Units**: FLOP/byte (or simply "ops/byte")
- **High AI** (e.g., 500 ops/byte): The GPU does many operations per byte loaded. The workload is **compute-bound** -- limited by the GPU's peak FLOPS.
- **Low AI** (e.g., 2 ops/byte): The GPU does very few operations per byte loaded. The workload is **memory-bandwidth-bound** -- limited by how fast data can stream from HBM.

## GPU Hardware Specifications

### Roofline Parameters

| GPU | Peak FP16 FLOPS | HBM Bandwidth | HBM Capacity | Ridge Point (ops/byte) |
|-----|-----------------|---------------|-------------- |------------------------|
| A100 SXM 80GB | 312 TFLOPS | 2,039 GB/s | 80 GB HBM2e | 153 |
| H100 SXM 80GB | 989 TFLOPS | 3,350 GB/s | 80 GB HBM3 | 295 |
| H200 SXM 141GB | 989 TFLOPS | 4,800 GB/s | 141 GB HBM3e | 206 |
| B200 SXM 192GB | 2,250 TFLOPS | 8,000 GB/s | 192 GB HBM3e | 281 |

### Understanding the Ridge Point

The **ridge point** is the arithmetic intensity where a workload transitions from memory-bound to compute-bound:

```
Ridge Point = Peak FLOPS / Peak Bandwidth
```

- If `AI < Ridge Point` --> memory-bandwidth-bound (performance = AI x Bandwidth)
- If `AI >= Ridge Point` --> compute-bound (performance = Peak FLOPS)

For the H100: Ridge Point = 989 TFLOPS / 3,350 GB/s = **295 ops/byte**

This means any workload with AI < 295 is memory-bound on H100. As we will show, autoregressive decode at batch size 1 has AI ~= 1, which is **295x below** the ridge point.

## LLM Inference Phases

LLM inference consists of two fundamentally different computational phases.

### Phase 1: Prefill (Prompt Processing)

During prefill, the model processes all input tokens in parallel through every transformer layer.

**FLOPs calculation:**
```
FLOPs_prefill ≈ 2 x P x S x B
```

Where:
- `P` = number of model parameters
- `S` = sequence length (number of input tokens)
- `B` = batch size
- Factor of 2 = one multiply + one add per parameter per token

**Bytes accessed:**
```
Bytes_prefill ≈ 2 x P    (for FP16 weights, 2 bytes per parameter)
```

The weights are loaded once from HBM and reused across all S tokens in the sequence.

**Arithmetic Intensity of Prefill:**
```
AI_prefill = (2 x P x S x B) / (2 x P) = S x B
```

The parameter count P cancels out. Arithmetic intensity depends only on sequence length and batch size.

**Example**: Llama 70B, S=2048, B=1:
```
AI_prefill = 2048 x 1 = 2048 ops/byte
```

This is well above any GPU's ridge point, so **prefill is compute-bound**.

### Phase 2: Decode (Token Generation)

During decode, the model generates one token at a time per sequence. Each step processes just 1 new token through all layers.

**FLOPs calculation:**
```
FLOPs_decode ≈ 2 x P x 1 x B = 2 x P x B
```

Only 1 token is processed per forward pass per sequence.

**Bytes accessed:**
```
Bytes_decode ≈ 2 x P    (entire model weights loaded each step)
```

The full model weights must be streamed from HBM for every single generated token.

**Arithmetic Intensity of Decode:**
```
AI_decode = (2 x P x B) / (2 x P) = B
```

The arithmetic intensity of decode equals the batch size.

**Example**: Llama 70B, B=1:
```
AI_decode = 1 ops/byte
```

This is **295x below** the H100 ridge point. Decode at B=1 is catastrophically memory-bound.

### Summary: Prefill vs Decode

| Phase | FLOPs | Bytes | AI | Bound by |
|-------|-------|-------|----|----------|
| Prefill | 2 x P x S x B | 2 x P | S x B | Compute (when S x B > ridge point) |
| Decode | 2 x P x 1 x B | 2 x P | B | Memory bandwidth (when B < ridge point) |

## Worked Examples by GPU

### Example 1: Llama 70B on H100 SXM

**Prefill** (S=2048, B=1):
```
FLOPs  = 2 x 70.6e9 x 2048 x 1 = 289.2 TFLOP
Bytes  = 2 x 70.6e9 = 141.2 GB
AI     = 2048 ops/byte

Time (compute-bound) = 289.2 TFLOP / 989 TFLOPS = 0.292 s
Time (memory-bound)  = 141.2 GB / 3,350 GB/s = 0.042 s

Bottleneck: Compute (0.292s >> 0.042s)
Effective: ~292 ms for 2048-token prefill
TTFT: ~292 ms
```

**Decode** (B=1):
```
FLOPs  = 2 x 70.6e9 x 1 = 141.2 GFLOP
Bytes  = 2 x 70.6e9 = 141.2 GB
AI     = 1 ops/byte

Time (compute-bound) = 0.141 TFLOP / 989 TFLOPS = 0.000143 s
Time (memory-bound)  = 141.2 GB / 3,350 GB/s = 0.0421 s

Bottleneck: Memory bandwidth (0.042s >> 0.000143s)
Effective: ~42 ms per token
Decode throughput: ~23.7 tokens/s per sequence
```

**Decode** (B=64):
```
FLOPs  = 2 x 70.6e9 x 64 = 9.04 TFLOP
Bytes  = 2 x 70.6e9 = 141.2 GB  (weights loaded once, shared across batch)
AI     = 64 ops/byte

Time (compute-bound) = 9.04 TFLOP / 989 TFLOPS = 0.00914 s
Time (memory-bound)  = 141.2 GB / 3,350 GB/s = 0.0421 s

Bottleneck: Still memory-bound (AI=64 < ridge=295)
Effective: ~42 ms per step, but generates 64 tokens
Aggregate throughput: 64 / 0.042 = ~1,523 tokens/s
```

### Example 2: Llama 70B on H200 SXM

**Decode** (B=1):
```
Bytes  = 141.2 GB
Time   = 141.2 GB / 4,800 GB/s = 0.0294 s

Decode throughput: ~34.0 tokens/s  (vs 23.7 on H100 -- 43% faster)
```

The H200 has 43% more memory bandwidth than H100 (4,800 vs 3,350 GB/s), directly translating to 43% faster decode at low batch sizes.

### Example 3: Llama 70B on B200 SXM

**Decode** (B=1):
```
Bytes  = 141.2 GB
Time   = 141.2 GB / 8,000 GB/s = 0.01765 s

Decode throughput: ~56.7 tokens/s  (vs 23.7 on H100 -- 139% faster)
```

### Example 4: Llama 8B on H100 SXM

**Prefill** (S=2048, B=1):
```
FLOPs  = 2 x 8.03e9 x 2048 = 32.9 TFLOP
Bytes  = 2 x 8.03e9 = 16.06 GB
AI     = 2048 ops/byte

Time = 32.9 TFLOP / 989 TFLOPS = 0.033 s
TTFT: ~33 ms
```

**Decode** (B=1):
```
Bytes  = 16.06 GB
Time   = 16.06 GB / 3,350 GB/s = 0.00479 s

Decode throughput: ~209 tokens/s
```

### Example 5: Llama 405B on 2xH100 Nodes (TP=8, PP=2)

**Decode** (B=1):
```
Total params = 405e9
Bytes per GPU = (2 x 405e9) / 16 = 50.6 GB per GPU
Time = 50.6 GB / 3,350 GB/s = 0.0151 s  (per pipeline stage)
Total time (PP=2) = 2 x 0.0151 = 0.0302 s  (+ communication overhead)

Decode throughput: ~30-33 tokens/s (with pipeline bubble and comm overhead)
```

## Why Decode Is Almost Always Memory-Bound

The ridge point for modern GPUs ranges from 153 (A100) to 295 (H100). Decode arithmetic intensity equals the batch size B. Therefore, decode is memory-bound whenever:

```
B < Ridge Point
```

| GPU | Ridge Point | Decode becomes compute-bound at B > |
|-----|-------------|--------------------------------------|
| A100 | 153 | B > 153 |
| H100 | 295 | B > 295 |
| H200 | 206 | B > 206 |
| B200 | 281 | B > 281 |

In practice, batch sizes of 100+ are common only in high-throughput offline batch processing. For interactive serving with latency SLAs (P99 TTFT < 500ms, P99 ITL < 100ms), typical batch sizes are 1-32. **Decode is memory-bound in virtually all interactive serving scenarios.**

## Why Prefill Is Compute-Bound

Prefill AI = S x B. Even with B=1, a prompt of S=512 tokens gives AI=512, which exceeds all GPU ridge points. Prefill is compute-bound for any reasonable prompt length (S >= 300 on H100).

The rare exception is very short prompts (S < 100) at B=1, where prefill might become memory-bound. In practice, prompts are typically 500-4000 tokens.

## Practical Implications

### 1. Decode Performance = Memory Bandwidth

Since decode is memory-bound, the single most important hardware spec for interactive LLM serving is **HBM bandwidth**:

```
Decode tokens/s ≈ HBM_bandwidth / (2 x P)   [for FP16, B=1]
```

| GPU | Bandwidth | Llama 70B decode tok/s (B=1) |
|-----|-----------|------------------------------|
| A100 | 2,039 GB/s | ~14.4 |
| H100 | 3,350 GB/s | ~23.7 |
| H200 | 4,800 GB/s | ~34.0 |
| B200 | 8,000 GB/s | ~56.7 |

### 2. Prefill Performance = Peak FLOPS

Since prefill is compute-bound, TTFT is determined by peak FLOPS:

```
TTFT ≈ (2 x P x S) / Peak_FLOPS
```

The B200's 2,250 TFLOPS gives 2.3x faster prefill than H100's 989 TFLOPS.

### 3. Disaggregated Prefill/Decode

Because prefill and decode have fundamentally different computational profiles:

- **Prefill**: Compute-bound, benefits from maximum FLOPS, runs efficiently at high GPU utilization
- **Decode**: Memory-bound, benefits from maximum bandwidth, underutilizes compute at low batch sizes

Running both on the same GPU forces a compromise. Disaggregated P/D separates them:

- **Prefill pods**: Optimized for compute (high SM count, large batch accumulation)
- **Decode pods**: Optimized for bandwidth (could use more, smaller GPUs or MIG slices)

This is why Profile E (disaggregated P/D) can achieve better overall throughput than Profile B (combined P/D on same GPUs).

### 4. MIG for Decode: Smaller Slices Are Fine

Since decode is memory-bound and underutilizes compute, running decode on MIG slices makes sense:

- A MIG 1g.10gb slice has 1/7th the SMs but 1/8th the bandwidth of a full H100
- Decode at B=1 uses <1% of the H100's compute anyway
- A single H100 can serve 7 independent Llama 8B FP8 instances on MIG slices
- Each slice gets ~419 GB/s bandwidth, sufficient for the small model

### 5. FP8 Quantization: Doubles Effective Arithmetic Intensity

FP8 halves the bytes per parameter (1 byte vs 2 bytes for FP16):

```
Bytes_FP8 = 1 x P    (vs 2 x P for FP16)
AI_decode_FP8 = (2 x P x B) / (1 x P) = 2B    (vs B for FP16)
```

FP8 doubles the arithmetic intensity and halves the memory bandwidth required:

| Precision | Llama 70B Size | Decode tok/s (H100, B=1) |
|-----------|---------------|--------------------------|
| FP16 | 141.2 GB | ~23.7 |
| FP8 | 70.6 GB | ~47.5 |

This is why Profile C (FP8, TP=2) can match Profile B (FP16, TP=4) with half the GPUs.

### 6. Batching: Linear AI Increase

Increasing batch size increases arithmetic intensity linearly:

```
AI_decode = B
```

| Batch Size | AI (decode) | H100 Status | Aggregate tok/s (70B FP16) |
|-----------|-------------|-------------|--------------------------|
| 1 | 1 | Memory-bound | ~24 |
| 8 | 8 | Memory-bound | ~190 |
| 32 | 32 | Memory-bound | ~762 |
| 128 | 128 | Memory-bound | ~3,048 |
| 295 | 295 | Ridge point | ~7,014 |
| 512 | 512 | Compute-bound | ~7,014 (capped at peak FLOPS) |

Note: At very high batch sizes, the KV cache consumes significant HBM, reducing available memory for model weights and potentially requiring offloading. Practical maximum batch sizes are limited by GPU memory.

## Model-Specific Analysis

### Decode Performance by Model and GPU

| Model | Params | FP16 Size | FP8 Size | H100 tok/s (B=1) | H200 tok/s (B=1) | B200 tok/s (B=1) |
|-------|--------|-----------|----------|-------------------|-------------------|-------------------|
| Llama 3.1 8B | 8.03B | 16.06 GB | 8.03 GB | ~209 | ~299 | ~499 |
| Llama 3.3 70B | 70.6B | 141.2 GB | 70.6 GB | ~24 | ~34 | ~57 |
| Llama 3.1 405B | 405B | 810 GB | 405 GB | ~8* | ~12* | ~20* |

*Multi-GPU, includes communication overhead. Actual throughput depends on TP/PP configuration.

### GPU Count Requirements

| Model | FP16 GPUs (H100 80GB) | FP8 GPUs (H100 80GB) | FP16 GPUs (H200 141GB) |
|-------|----------------------|---------------------|----------------------|
| Llama 8B | 1 | 1 (MIG 1g.10gb) | 1 |
| Llama 70B | 2 (tight) / 4 (comfortable) | 1 (tight) / 2 (comfortable) | 1 |
| Llama 405B | 16 (2 nodes) | 8 (1 node) | 8 (1 node) |

"Comfortable" accounts for KV cache, runtime overhead, and CUDA context memory. At `gpu_memory_utilization=0.90`, approximately 72 GB is available per H100 for model + KV cache.

### KV Cache Memory Analysis

KV cache per token per layer (FP16):
```
KV_bytes = 2 x num_layers x 2 x num_kv_heads x head_dim x 2_bytes
```

| Model | Layers | KV Heads | Head Dim | KV per Token | KV for 8192 Tokens |
|-------|--------|----------|----------|-------------|-------------------|
| Llama 8B | 32 | 8 (GQA) | 128 | 128 KB | 1.0 GB |
| Llama 70B | 80 | 8 (GQA) | 128 | 320 KB | 2.5 GB |
| Llama 405B | 126 | 8 (GQA) | 128 | 504 KB | 4.0 GB |

With 100 concurrent sequences at 8192 context length:
- Llama 8B: 100 GB KV cache (exceeds single GPU, need batching control)
- Llama 70B: 250 GB KV cache (spread across TP GPUs)
- In practice, vLLM's PagedAttention manages KV cache efficiently with preemption

## Summary Decision Matrix

| Scenario | Key Metric | Optimization Strategy |
|----------|-----------|----------------------|
| Low-latency chat (B=1-4) | Memory bandwidth | Choose H200/B200, use FP8, minimize model size |
| Batch processing (B=64+) | Peak FLOPS | Choose H100/B200, maximize GPU utilization |
| Long prompts (S=4K+) | Peak FLOPS (prefill) | Chunk prefill, enable prefix caching |
| Multi-model serving | Memory capacity | Use MIG, FP8, maximize models per GPU |
| Cost-optimized | $/token | FP8 on fewer GPUs, MIG for small models |
| Latency-critical | TTFT + ITL | EAGLE3 speculative decoding, disaggregated P/D |
