# GPU Roofline Model for LLM Inference

## What Is a Roofline Model?

The roofline model is a visual performance analysis framework that shows the theoretical peak performance achievable by a workload on a given piece of hardware. It plots **attainable performance** (FLOPS) as a function of **arithmetic intensity** (FLOP/byte).

The model creates a "roofline" from two hardware limits:

1. **Memory bandwidth ceiling**: A diagonal line where performance = AI x Bandwidth
2. **Compute ceiling**: A horizontal line at peak FLOPS

The intersection of these two lines is the **ridge point** -- the arithmetic intensity where a workload transitions from memory-bound to compute-bound.

## How to Read a Roofline Plot

```
Performance
(TFLOPS)
    ^
    |                              _________________ Peak FLOPS
    |                             /
    |                            /
    |                           /
    |                          /   <-- Compute ceiling
    |                         /
    |                        /
    |          Memory BW    / <-- Ridge point
    |          ceiling --> /
    |                    /
    |                   /
    |                  /
    |                 /
    |                /
    |               /
    +--+---+---+---+---+---+---+---+---+---+---+--> Arithmetic Intensity
       1   2   4   8  16  32  64 128 256 512 1024    (FLOP/byte, log scale)
```

- **X-axis** (log scale): Arithmetic intensity (FLOP/byte)
- **Y-axis** (log scale): Attainable performance (TFLOPS)
- **Below the roofline**: Achievable performance region
- **On the roofline**: Theoretical maximum

A workload is plotted as a point at its (AI, achieved FLOPS) coordinate:
- **Left of ridge point**: Memory-bound. Performance increases linearly with AI.
- **Right of ridge point**: Compute-bound. Performance is flat at peak FLOPS.

## Roofline Analysis per GPU

### NVIDIA A100 SXM 80GB

```
Performance (TFLOPS)
 312 |...........................__________________________________
     |                        /
 200 |                       /
     |                      /
 100 |                     /
     |                    /
  50 |                   /
     |                  /
  20 |                 /
     |                /
  10 |               /
     |              /
   2 |        D   /
   1 |  d   /
     +--+---+---+---+---+---+---+---+---+---+---+-->
        1   2   4   8  16  32  64 128 256 512 2048
                                       ^
                            Ridge: 153 ops/byte

  d = Decode B=1 (AI=1)     --> 2.04 TFLOPS achieved (0.65% utilization)
  D = Decode B=32 (AI=32)   --> 65.2 TFLOPS achieved (20.9% utilization)
  P = Prefill S=2048 (AI=2048) --> 312 TFLOPS (compute ceiling)
```

| Metric | Value |
|--------|-------|
| Peak FP16 FLOPS | 312 TFLOPS |
| HBM2e Bandwidth | 2,039 GB/s |
| HBM Capacity | 80 GB |
| Ridge Point | 153 ops/byte |
| Decode B=1 utilization | 0.65% |
| Decode reaches compute-bound at | B > 153 |

### NVIDIA H100 SXM 80GB

```
Performance (TFLOPS)
 989 |...........................__________________________________
     |                        /
 500 |                       /
     |                      /
 200 |                     /
     |                    /
 100 |                   /
     |                  /
  50 |                 /
     |                /
  10 |               /
     |              /
   3 |        D   /
   1 |  d   /
     +--+---+---+---+---+---+---+---+---+---+---+-->
        1   2   4   8  16  32  64 128 256 512 2048
                                           ^
                                Ridge: 295 ops/byte

  d = Decode B=1 (AI=1)     --> 3.35 TFLOPS achieved (0.34% utilization)
  D = Decode B=32 (AI=32)   --> 107 TFLOPS achieved (10.8% utilization)
  P = Prefill S=2048 (AI=2048) --> 989 TFLOPS (compute ceiling)
```

| Metric | Value |
|--------|-------|
| Peak FP16 FLOPS | 989 TFLOPS |
| HBM3 Bandwidth | 3,350 GB/s |
| HBM Capacity | 80 GB |
| Ridge Point | 295 ops/byte |
| Decode B=1 utilization | 0.34% |
| Decode reaches compute-bound at | B > 295 |

The H100 has 3.17x more FLOPS than A100 but only 1.64x more bandwidth. This makes the H100 **proportionally worse for decode at low batch sizes** compared to its prefill improvement. The higher ridge point means decode is memory-bound over a wider range of batch sizes.

### NVIDIA H200 SXM 141GB

```
Performance (TFLOPS)
 989 |...................__________________________________
     |                 /
 500 |                /
     |               /
 200 |              /
     |             /
 100 |            /
     |           /
  50 |          /
     |         /
  10 |        /
   5 |  d   /
     |     /
   1 |    /
     +--+---+---+---+---+---+---+---+---+---+---+-->
        1   2   4   8  16  32  64 128 256 512 2048
                                       ^
                            Ridge: 206 ops/byte

  d = Decode B=1 (AI=1)     --> 4.80 TFLOPS achieved (0.49% utilization)
  D = Decode B=32 (AI=32)   --> 153.6 TFLOPS achieved (15.5% utilization)
  P = Prefill S=2048 (AI=2048) --> 989 TFLOPS (compute ceiling)
```

| Metric | Value |
|--------|-------|
| Peak FP16 FLOPS | 989 TFLOPS (same as H100) |
| HBM3e Bandwidth | 4,800 GB/s |
| HBM Capacity | 141 GB |
| Ridge Point | 206 ops/byte |
| Decode B=1 utilization | 0.49% |
| Decode reaches compute-bound at | B > 206 |

The H200 has the same FLOPS as H100 but 43% more bandwidth and 76% more memory. This lowers the ridge point, meaning decode becomes compute-bound at lower batch sizes. The H200 is specifically designed for LLM inference where memory bandwidth dominates.

### NVIDIA B200 SXM 192GB

```
Performance (TFLOPS)
2250 |...........................__________________________________
     |                        /
1000 |                       /
     |                      /
 500 |                     /
     |                    /
 200 |                   /
     |                  /
 100 |                 /
     |                /
  50 |               /
     |              /
   8 |        D   /
   1 |  d   /
     +--+---+---+---+---+---+---+---+---+---+---+-->
        1   2   4   8  16  32  64 128 256 512 2048
                                           ^
                                Ridge: 281 ops/byte

  d = Decode B=1 (AI=1)     --> 8.00 TFLOPS achieved (0.36% utilization)
  D = Decode B=32 (AI=32)   --> 256 TFLOPS achieved (11.4% utilization)
  P = Prefill S=2048 (AI=2048) --> 2,250 TFLOPS (compute ceiling)
```

| Metric | Value |
|--------|-------|
| Peak FP16 FLOPS | 2,250 TFLOPS |
| HBM3e Bandwidth | 8,000 GB/s |
| HBM Capacity | 192 GB |
| Ridge Point | 281 ops/byte |
| Decode B=1 utilization | 0.36% |
| Decode reaches compute-bound at | B > 281 |

The B200 doubles both FLOPS and bandwidth relative to H100, maintaining a similar ridge point. It excels at both prefill (2.3x faster) and decode (2.4x faster).

## Where Prefill and Decode Land at Various Batch Sizes

### Decode Phase

| Batch Size | AI | A100 | H100 | H200 | B200 |
|-----------|-----|------|------|------|------|
| 1 | 1 | Mem-bound | Mem-bound | Mem-bound | Mem-bound |
| 4 | 4 | Mem-bound | Mem-bound | Mem-bound | Mem-bound |
| 16 | 16 | Mem-bound | Mem-bound | Mem-bound | Mem-bound |
| 32 | 32 | Mem-bound | Mem-bound | Mem-bound | Mem-bound |
| 64 | 64 | Mem-bound | Mem-bound | Mem-bound | Mem-bound |
| 128 | 128 | Mem-bound | Mem-bound | Mem-bound | Mem-bound |
| 153 | 153 | **Ridge** | Mem-bound | Mem-bound | Mem-bound |
| 206 | 206 | Comp-bound | Mem-bound | **Ridge** | Mem-bound |
| 281 | 281 | Comp-bound | Mem-bound | Comp-bound | **Ridge** |
| 295 | 295 | Comp-bound | **Ridge** | Comp-bound | Comp-bound |
| 512 | 512 | Comp-bound | Comp-bound | Comp-bound | Comp-bound |

### Prefill Phase (B=1)

| Sequence Length | AI | A100 | H100 | H200 | B200 |
|----------------|-----|------|------|------|------|
| 64 | 64 | Mem-bound | Mem-bound | Mem-bound | Mem-bound |
| 128 | 128 | Mem-bound | Mem-bound | Mem-bound | Mem-bound |
| 153 | 153 | **Ridge** | Mem-bound | Mem-bound | Mem-bound |
| 256 | 256 | Comp-bound | Mem-bound | Comp-bound | Mem-bound |
| 295 | 295 | Comp-bound | **Ridge** | Comp-bound | Comp-bound |
| 512 | 512 | Comp-bound | Comp-bound | Comp-bound | Comp-bound |
| 1024 | 1024 | Comp-bound | Comp-bound | Comp-bound | Comp-bound |
| 2048 | 2048 | Comp-bound | Comp-bound | Comp-bound | Comp-bound |

Prefill with typical prompt lengths (512-4096 tokens) is compute-bound on all modern GPUs.

## Implications for GPU Selection

### When to Choose H100

- **High batch-size throughput**: The H100's high FLOPS (989 TFLOPS) excels when batch sizes push past the ridge point
- **Prefill-dominated workloads**: Long prompts with short outputs benefit from H100's compute power
- **Cost-effective**: H100 is widely available and cheaper per GPU-hour than H200/B200
- **MIG flexibility**: H100 supports MIG for running multiple smaller models

### When to Choose H200

- **Low-latency decode**: 43% more bandwidth than H100 directly translates to faster token generation
- **Large models on fewer GPUs**: 141 GB capacity lets Llama 70B FP16 fit on 2 GPUs (tight) vs 2-4 on H100
- **Interactive chat**: Where per-user decode latency matters more than aggregate throughput
- **Same FLOPS as H100**: Prefill performance is identical; you get faster decode for free

### When to Choose B200

- **Maximum decode speed**: 8,000 GB/s bandwidth yields 2.4x faster decode than H100
- **Maximum prefill speed**: 2,250 TFLOPS yields 2.3x faster prefill than H100
- **Largest models on fewer GPUs**: 192 GB capacity fits Llama 70B FP16 on a single GPU
- **Future-proofing**: Best choice for growing model sizes and higher context lengths

### Decision Matrix

| Priority | Best GPU | Reason |
|----------|----------|--------|
| Lowest latency (B=1) | B200 | Highest bandwidth |
| Best latency/$ | H200 | Good bandwidth, lower cost than B200 |
| Highest throughput (B=256+) | B200 | Highest FLOPS |
| Best throughput/$ | H100 | High FLOPS, widely available |
| Max models per GPU | H100 (MIG) | Best MIG support, mature ecosystem |
| Single-GPU Llama 70B | H200/B200 | 141/192 GB capacity |

## Effect of Quantization on Roofline Position

Quantization reduces bytes accessed per parameter, shifting workloads to the right on the roofline plot (higher AI):

| Precision | Bytes/Param | Decode AI (B=1) | Effect |
|-----------|------------|-----------------|--------|
| FP32 | 4 | 0.5 | Worst: 2x more memory-bound |
| FP16/BF16 | 2 | 1.0 | Baseline |
| FP8 | 1 | 2.0 | 2x closer to ridge point |
| INT4 (GPTQ/AWQ) | 0.5 | 4.0 | 4x closer to ridge point |

### FP8 on Roofline (H100)

```
Performance (TFLOPS)
 989 |...........................__________________________________
     |                        /
     |                       /
     |                      /
     |                     /
     |                    /
     |                   /
     |                  /
     |                 /
     |                /
     |               /
     |              /
   7 |        d8  /       (FP8 B=1: AI=2, achieved ~6.7 TFLOPS)
   3 |  d16 /             (FP16 B=1: AI=1, achieved ~3.35 TFLOPS)
     +--+---+---+---+---+---+---+---+---+---+---+-->
        1   2   4   8  16  32  64 128 256 512 2048
```

FP8 halves the model weight size, doubling the effective decode speed for memory-bound workloads. On H100:
- FP16 Llama 70B decode: ~24 tok/s
- FP8 Llama 70B decode: ~47 tok/s (2x improvement)

This makes FP8 the single most impactful optimization for interactive serving latency, assuming acceptable quality loss (typically <1% on benchmarks).
