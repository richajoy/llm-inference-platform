# MIG Sizing Guide

## Overview

Multi-Instance GPU (MIG) partitions a single physical GPU into multiple isolated instances, each with dedicated compute, memory, and bandwidth. This allows running multiple smaller models on a single GPU with hardware-level isolation.

MIG is supported on A100, H100, H200, and B200. This guide focuses on H100 MIG profiles as used in this platform.

## H100 SXM MIG Profiles

### Available Profiles

| Profile | GPU Memory | SMs | Memory BW (approx) | GPU Instances per H100 | Compute Slices |
|---------|-----------|-----|---------------------|----------------------|----------------|
| 1g.10gb | 10 GB | 16 (1/7) | ~419 GB/s | 7 | 1 |
| 1g.20gb | 20 GB | 16 (1/7) | ~838 GB/s | 4 | 1 |
| 2g.20gb | 20 GB | 32 (2/7) | ~838 GB/s | 3 | 2 |
| 3g.40gb | 40 GB | 48 (3/7) | ~1,675 GB/s | 2 | 3 |
| 4g.40gb | 40 GB | 64 (4/7) | ~1,675 GB/s | 1* | 4 |
| 7g.80gb | 80 GB | 114 (7/7) | ~3,350 GB/s | 1 | 7 |

*The 4g.40gb profile allows one additional 3g.40gb instance on the remaining resources.

### Memory Bandwidth Estimation

MIG memory bandwidth scales approximately linearly with memory slices:
```
Slice BW ≈ (Total HBM BW) x (Memory Slices / Total Memory Slices)
```

For H100 SXM (3,350 GB/s total, 8 memory slices):
- 1g.10gb (1 memory slice): ~419 GB/s
- 2g.20gb (2 memory slices): ~838 GB/s
- 3g.40gb (4 memory slices): ~1,675 GB/s

## Decision Tree: Model Size to MIG Profile

```
                        What model are you deploying?
                                    |
                    +---------------+---------------+
                    |               |               |
               <= 8B params    8B-30B params    >= 30B params
                    |               |               |
              What precision?  What precision?   Use full GPU
                    |               |            (no MIG)
              +-----+-----+   +----+----+
              |           |   |         |
            FP8         FP16  FP8     FP16
              |           |   |         |
         Model ~5GB  Model ~16GB  Model ~15-30GB
              |           |   |         |
         1g.10gb     2g.20gb  2g.20gb  3g.40gb
         (7 per GPU) (3/GPU)  (3/GPU)  (2/GPU)
```

## Profile Recommendations

### Llama 3.1 8B FP8 --> 1g.10gb

```
Model size (FP8):  ~5 GB
KV cache (4K ctx):  ~0.5 GB
CUDA overhead:      ~1 GB
Total required:     ~6.5 GB
Available:          10 GB
Headroom:           3.5 GB (sufficient)

Instances per H100: 7
```

**vLLM configuration:**
```yaml
args:
  - "--model=/models/meta-llama/Llama-3.1-8B-Instruct"
  - "--quantization=fp8"
  - "--max-model-len=4096"
  - "--gpu-memory-utilization=0.85"
resources:
  limits:
    nvidia.com/gpu: 1    # Requests one MIG slice
```

**Performance estimate:**
- Memory BW per slice: ~419 GB/s
- Decode (B=1): 5 GB / 419 GB/s = 11.9 ms/token = ~84 tok/s
- This is sufficient for single-user interactive chat

### Llama 3.1 8B FP16 --> 2g.20gb

```
Model size (FP16): ~16 GB
KV cache (4K ctx):  ~1 GB
CUDA overhead:      ~1 GB
Total required:     ~18 GB
Available:          20 GB
Headroom:           2 GB (tight but workable)

Instances per H100: 3
```

**vLLM configuration:**
```yaml
args:
  - "--model=/models/meta-llama/Llama-3.1-8B-Instruct"
  - "--max-model-len=4096"
  - "--gpu-memory-utilization=0.90"
resources:
  limits:
    nvidia.com/gpu: 1
```

### Llama 3.3 70B FP8 --> Full GPU (no MIG)

```
Model size (FP8): ~70.6 GB
Minimum GPUs:      1 (barely fits with 80GB HBM)
Comfortable:       2 GPUs with TP=2
```

The 70B model does not fit in any MIG slice. Use full GPUs with tensor parallelism.

### Llama 3.3 70B FP16 --> Full GPU x4 (no MIG)

```
Model size (FP16): ~141.2 GB
Minimum GPUs:       2 (with TP=2, ~70.6 GB per GPU)
Comfortable:        4 (with TP=4, ~35.3 GB per GPU + KV cache room)
```

## Multiple Instances Per GPU Calculations

### Scenario: Maximum Llama 8B FP8 Density on 8xH100

```
MIG config: all-1g-10gb (7 instances per GPU)

Total MIG instances: 8 GPUs x 7 instances = 56 instances
Total vLLM pods:     56 (one per MIG instance)
Concurrent models:   56 independent Llama 8B FP8 serving endpoints
```

Apply the `all-1g-10gb` MIG profile:
```bash
kubectl label node <node> nvidia.com/mig.config=all-1g-10gb --overwrite
```

The GPU Operator's MIG manager will automatically partition all 8 GPUs.

### Scenario: Mixed Workload on 8xH100

```
GPU 0-3: No MIG (full GPUs for Llama 70B TP=4)
GPU 4-7: MIG all-1g-10gb (28 MIG instances for Llama 8B FP8)
```

This requires the **mixed MIG strategy** (`values-mig-mixed.yaml`) where different GPUs have different MIG configurations. In practice, a single-node k3s cluster presents all GPUs as one node, so mixed MIG requires labeling at the GPU index level.

### Scenario: Balanced MIG on 8xH100

Using the `balanced` MIG profile:
```
Each GPU: 1x 3g.40gb + 1x 3g.40gb (or 2x 3g.40gb)

Total 3g.40gb instances: 8 x 2 = 16
Each can run: Llama 8B FP16 comfortably, or small models
```

## Performance vs Isolation Tradeoffs

### Performance Characteristics

| Aspect | Full GPU | MIG 3g.40gb | MIG 1g.10gb |
|--------|----------|-------------|-------------|
| Memory | 80 GB | 40 GB | 10 GB |
| SMs | 114 | 48 | 16 |
| Memory BW | 3,350 GB/s | ~1,675 GB/s | ~419 GB/s |
| Decode tok/s (8B FP8) | ~418 | ~209 | ~84 |
| Max batch size | Large | Medium | Small |
| Isolation | None (shared) | Hardware | Hardware |

### When MIG Makes Sense

- **Multi-tenant serving**: Hardware isolation between customers prevents noisy-neighbor effects
- **Small model serving**: 8B parameter models at FP8 fit comfortably in 1g.10gb
- **Cost optimization**: Running 7 independent Llama 8B instances is cheaper than 7 full GPUs
- **Development/testing**: Each developer gets an isolated GPU slice

### When to Avoid MIG

- **Large models**: 70B+ models need full GPUs with tensor parallelism
- **Maximum single-stream performance**: Full GPU bandwidth is needed for lowest latency
- **High batch sizes**: MIG slices have limited memory for KV cache
- **Dynamic workloads**: MIG reconfiguration requires a GPU reset (disrupts running workloads)

## How to Apply MIG Profiles

### Using GPU Operator (Recommended)

The NVIDIA GPU Operator manages MIG configuration through node labels.

**Step 1**: Install GPU Operator with MIG support:
```bash
make install-gpu-operator-mig
```

**Step 2**: Apply a MIG profile via node label:
```bash
# All GPUs as 1g.10gb slices (maximum density)
kubectl label node <node> nvidia.com/mig.config=all-1g-10gb --overwrite

# All GPUs as 3g.40gb slices (balanced)
kubectl label node <node> nvidia.com/mig.config=all-3g-40gb --overwrite

# Balanced profile (mix of slice sizes)
kubectl label node <node> nvidia.com/mig.config=balanced --overwrite
```

**Step 3**: The GPU Operator's MIG manager automatically:
1. Drains existing GPU workloads
2. Resets the GPUs
3. Creates the requested MIG instances
4. Updates the device plugin to advertise new resources

**Step 4**: Verify:
```bash
# Check MIG instances
nvidia-smi mig -lgi

# Check advertised resources
kubectl describe node <node> | grep nvidia.com/gpu
```

### MIG Profile ConfigMaps

The platform includes predefined MIG profiles in `platform/gpu-operator/mig-profiles/`:

**all-1g-10gb.yaml** (Maximum density):
```yaml
# 7x 1g.10gb per GPU = 56 instances on 8xH100
# Best for: Llama 8B FP8, maximum concurrent models
```

**all-3g-40gb.yaml** (Balanced):
```yaml
# 2x 3g.40gb per GPU = 16 instances on 8xH100
# Best for: Llama 8B FP16, medium models
```

**balanced.yaml** (Mixed):
```yaml
# Mix of 3g.40gb and 1g.10gb per GPU
# Best for: Running different model sizes simultaneously
```

## Monitoring MIG Instances

### DCGM Exporter Metrics

DCGM exports per-MIG-instance metrics when running on MIG-enabled GPUs:

```promql
# GPU utilization per MIG instance
DCGM_FI_PROF_GR_ENGINE_ACTIVE{gpu_instance_id!=""}

# Memory used per MIG instance
DCGM_FI_DEV_FB_USED{gpu_instance_id!=""}

# Memory free per MIG instance
DCGM_FI_DEV_FB_FREE{gpu_instance_id!=""}
```

### Key Alerts for MIG

```yaml
# Alert if any MIG instance is >95% memory
- alert: MIGInstanceMemoryHigh
  expr: DCGM_FI_DEV_FB_USED / (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE) > 0.95
  for: 5m

# Alert if MIG instances are not balanced (some idle, some saturated)
- alert: MIGLoadImbalance
  expr: stddev(DCGM_FI_PROF_GR_ENGINE_ACTIVE) > 0.3
  for: 10m
```

### Grafana Dashboard Panels

The `gpu-overview.json` dashboard includes MIG-specific panels:
- MIG Instance Memory Utilization (per-instance)
- MIG Instance Compute Utilization (per-instance)
- MIG Instance Count by Profile
- vLLM pods mapped to MIG instances

## Practical Checklist

1. Determine model size and precision
2. Calculate memory requirement (model + KV cache + overhead)
3. Select the smallest MIG profile that fits
4. Calculate instances per GPU and total instances
5. Apply MIG profile via GPU Operator node label
6. Deploy vLLM pods requesting `nvidia.com/gpu: 1` (each gets one MIG slice)
7. Verify with `nvidia-smi mig -lgi` and pod scheduling
8. Monitor with DCGM per-instance metrics
