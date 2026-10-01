# Profile: Llama 3.1 8B on MIG Slice

## Overview

Deploys `meta-llama/Llama-3.1-8B-Instruct` on a single NVIDIA H100 MIG 1g.10gb slice. This profile is optimized for low-latency, cost-efficient inference suitable for lightweight tasks, testing, and development workloads.

## Configuration

| Parameter | Value |
|-----------|-------|
| Model | meta-llama/Llama-3.1-8B-Instruct |
| GPUs | 1 (MIG 1g.10gb) |
| Tensor Parallelism | 1 |
| Max Model Length | 4096 tokens |
| Max Concurrent Sequences | 64 |
| GPU Memory Utilization | 90% |
| Prefix Caching | Enabled |

## Prerequisites

- GPU Operator installed with MIG manager enabled
- MIG profile `1g.10gb` configured on at least one H100 GPU
- Model weights downloaded to the `model-weights` PVC

## Deployment

```bash
# Apply with kustomize
kubectl apply -k inference/vllm/profiles/llama-8b-mig/

# Or via make
make deploy-8b-mig
```

## Verification

```bash
# Check pod status
kubectl get pods -n inference -l app=vllm-8b-mig

# Test the endpoint
kubectl run curl --rm -it --image=curlimages/curl -- \
  curl -s http://vllm-8b-mig.inference:8000/v1/models | jq .

# Run a completion
kubectl run curl --rm -it --image=curlimages/curl -- \
  curl -s http://vllm-8b-mig.inference:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"meta-llama/Llama-3.1-8B-Instruct","prompt":"Hello","max_tokens":32}'
```

## Expected Performance

- TTFT (Time to First Token): ~50-100ms for short prompts
- Throughput: ~1500-2000 tokens/s (output)
- Memory footprint: ~8GB (fits within 10GB MIG slice)
