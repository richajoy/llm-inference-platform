# Profile: Llama 3.3 70B FP8 with TP=2

## Overview

Deploys `nvidia/Llama-3.3-70B-Instruct-FP8` -- NVIDIA's pre-quantized FP8 checkpoint -- across just 2 H100 GPUs. This profile delivers near-full-precision quality with 50% fewer GPUs than the TP=4 profile, making it the most cost-efficient way to serve the 70B model.

## Configuration

| Parameter | Value |
|-----------|-------|
| Model | nvidia/Llama-3.3-70B-Instruct-FP8 |
| GPUs | 2 x H100 80GB |
| Tensor Parallelism | 2 |
| Max Model Length | 16384 tokens |
| GPU Memory Utilization | 95% |
| KV Cache Dtype | FP8 |
| Prefix Caching | Enabled |

## Key Advantages

- **2 GPUs vs 4**: Halves GPU cost compared to the TP=4 full-precision profile
- **Longer context**: Supports 16K tokens vs 8K in the TP=4 profile
- **95% GPU utilization**: FP8 weights leave more room for KV cache
- **Negligible quality loss**: NVIDIA's FP8 quantization preserves model quality within ~0.5% of BF16

## Prerequisites

- 2 H100 80GB GPUs on a single node with NVLink
- Model weights downloaded (`nvidia/Llama-3.3-70B-Instruct-FP8`)

## Deployment

```bash
kubectl apply -k inference/vllm/profiles/llama-70b-fp8-tp2/

# Or via make
make deploy-70b-fp8
```

## Verification

```bash
kubectl get pods -n inference -l app=vllm-70b-fp8-tp2

kubectl run curl --rm -it --image=curlimages/curl -- \
  curl -s http://vllm-70b-fp8-tp2.inference:8000/v1/models | jq .
```

## Expected Performance

- TTFT: ~200-400ms for 1K input tokens
- Throughput: ~3000-5000 tokens/s aggregate (output)
- Model loading time: ~1-2 minutes (smaller FP8 weights)
