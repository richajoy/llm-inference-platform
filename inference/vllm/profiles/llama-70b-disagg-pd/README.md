# Profile: Llama 3.3 70B Disaggregated Prefill/Decode

## Overview

Deploys `meta-llama/Llama-3.3-70B-Instruct` in a disaggregated architecture where prefill (prompt processing) and decode (token generation) run on separate GPU sets. A lightweight proxy routes client requests through the prefill-then-decode pipeline.

This architecture optimizes for high-throughput scenarios where prefill and decode have different resource characteristics: prefill is compute-bound (large matrix multiplications) while decode is memory-bandwidth-bound (sequential KV cache reads).

## Architecture

```
Client --> [Proxy :8000] --> [Prefill :8100] --> KV Cache Transfer --> [Decode :8200]
                                                   (LMCacheConnectorV1 / NIXL)
```

### Components

| Component | Port | GPUs | Role |
|-----------|------|------|------|
| Prefill | 8100 | GPU 0-3 (TP=4) | KV producer -- processes prompts |
| Decode | 8200 | GPU 4-7 (TP=4) | KV consumer -- generates tokens |
| Proxy | 8000 | None | Routes requests through P/D pipeline |

## Configuration

| Parameter | Prefill | Decode |
|-----------|---------|--------|
| Model | Llama-3.3-70B-Instruct | Llama-3.3-70B-Instruct |
| TP | 4 | 4 |
| KV Role | kv_producer | kv_consumer |
| KV Connector | LMCacheConnectorV1 | LMCacheConnectorV1 |
| CUDA Devices | 0,1,2,3 | 4,5,6,7 |
| GPU Memory | 90% | 90% |

## KV Cache Transfer

Uses LMCache with NIXL (NVMe-accelerated Inter-node eXchange Library) for high-bandwidth KV cache transfer between prefill and decode instances. The LMCache ConfigMap provides separate configs for sender (prefill) and receiver (decode) roles.

## Prerequisites

- 8 H100 80GB GPUs (4 for prefill, 4 for decode)
- Model weights downloaded to the `model-weights` PVC
- LMCache ConfigMap deployed (included in kustomization)

## Deployment

```bash
kubectl apply -k inference/vllm/profiles/llama-70b-disagg-pd/

# Or via make
make deploy-70b-disagg
```

## Verification

```bash
# Check all three pods
kubectl get pods -n inference -l profile=disagg-pd

# Test via the proxy endpoint
kubectl run curl --rm -it --image=curlimages/curl -- \
  curl -s http://vllm-70b-disagg.inference:8000/v1/models | jq .

# Check KV transfer logs
kubectl logs -n inference -l role=prefill | grep -i "kv\|lmcache\|nixl"
kubectl logs -n inference -l role=decode | grep -i "kv\|lmcache\|nixl"
```

## When to Use

- **High-throughput batch inference**: Long prompts with many concurrent users
- **Asymmetric scaling**: Scale prefill and decode independently
- **Large prompt workloads**: RAG, document processing, code generation with large context

## Expected Performance

- TTFT: Higher than monolithic (additional KV transfer latency ~50-100ms)
- Aggregate throughput: 1.5-2x higher than monolithic TP=4 at high concurrency
- Best at high request rates where prefill/decode contention is the bottleneck
