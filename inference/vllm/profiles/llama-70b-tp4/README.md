# Profile: Llama 3.3 70B with TP=4

## Overview

Deploys `meta-llama/Llama-3.3-70B-Instruct` with tensor parallelism across 4 H100 GPUs. This is the primary production profile for the full-precision 70B model, providing the best throughput-to-quality ratio.

## Configuration

| Parameter | Value |
|-----------|-------|
| Model | meta-llama/Llama-3.3-70B-Instruct |
| GPUs | 4 x H100 80GB |
| Tensor Parallelism | 4 |
| Max Model Length | 8192 tokens |
| Max Batched Tokens | 8192 |
| Max Concurrent Sequences | 256 |
| GPU Memory Utilization | 90% |
| KV Cache Dtype | FP8 |
| Prefix Caching | Enabled |
| Chunked Prefill | Enabled |
| Shared Memory | 16Gi |

## Key Optimizations

- **FP8 KV Cache**: Reduces KV cache memory by ~50%, enabling more concurrent sequences
- **Chunked Prefill**: Allows interleaving prefill chunks with decode steps, reducing head-of-line blocking
- **Prefix Caching**: Deduplicates KV cache for shared prompt prefixes across requests

## Prerequisites

- 4 H100 80GB GPUs available on a single node
- NVLink/NVSwitch connectivity for inter-GPU communication
- Model weights downloaded to the `model-weights` PVC

## Deployment

```bash
kubectl apply -k inference/vllm/profiles/llama-70b-tp4/

# Or via make
make deploy-70b-tp4
```

## Verification

```bash
kubectl get pods -n inference -l app=vllm-70b-tp4

kubectl run curl --rm -it --image=curlimages/curl -- \
  curl -s http://vllm-70b-tp4.inference:8000/v1/models | jq .
```

## Expected Performance

- TTFT: ~200-400ms for 1K input tokens
- Throughput: ~4000-6000 tokens/s aggregate (output)
- Model loading time: ~2-4 minutes
