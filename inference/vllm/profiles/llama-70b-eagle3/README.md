# Profile: Llama 3.3 70B + EAGLE3 Speculative Decoding

## Overview

Deploys `meta-llama/Llama-3.3-70B-Instruct` with the EAGLE3 speculative decoding draft model `yuhuili/EAGLE3-LLaMA3.3-Instruct-70B`. EAGLE3 uses a lightweight draft model to predict multiple tokens ahead, which the main model then verifies in a single forward pass. This achieves 2-3x latency reduction for decode-bound workloads.

## Configuration

| Parameter | Value |
|-----------|-------|
| Target Model | meta-llama/Llama-3.3-70B-Instruct |
| Draft Model | yuhuili/EAGLE3-LLaMA3.3-Instruct-70B |
| Method | eagle3 |
| Speculative Tokens | 3 |
| GPUs | 4 x H100 80GB |
| Target TP | 4 |
| Draft TP | 1 |
| Max Model Length | 8192 tokens |
| GPU Memory Utilization | 90% |
| Prefix Caching | Enabled |

## How EAGLE3 Works

1. The lightweight draft model generates `num_speculative_tokens` candidate tokens
2. The target model verifies all candidates in a single batched forward pass
3. Accepted tokens are emitted; rejected tokens trigger re-draft from the rejection point
4. Average acceptance rate is ~70-80%, yielding significant latency improvement

## When to Use This Profile

- **Low-latency interactive use cases**: chatbots, real-time assistants
- **Decode-bound workloads**: where per-token latency matters more than aggregate throughput
- **Single-user or low-concurrency**: speculative decoding overhead increases with batch size

## Prerequisites

- 4 H100 80GB GPUs on a single node
- Both target and draft model weights downloaded to the PVC

## Deployment

```bash
kubectl apply -k inference/vllm/profiles/llama-70b-eagle3/

# Or via make
make deploy-70b-eagle3
```

## Verification

```bash
kubectl get pods -n inference -l app=vllm-70b-eagle3

# Check that speculative decoding is active in logs
kubectl logs -n inference -l app=vllm-70b-eagle3 | grep -i "speculative\|eagle"
```

## Expected Performance

- TTFT: ~200-400ms (similar to non-speculative)
- Per-token latency: ~15-25ms (vs ~40-60ms without speculation)
- Acceptance rate: ~70-80% with 3 speculative tokens
- Best suited for batch_size <= 8 (overhead increases with concurrency)
