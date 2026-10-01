# vLLM Deployment Profiles

Production-ready deployment profiles for Llama 3.1 models on H100 GPU clusters. Each profile optimizes for a different dimension (cost, latency, throughput, or scale) using specific GPU configurations and vLLM features.

## Profile Overview

| Profile | Model | GPUs | Key Feature | Cost/hr | Use Case |
|---------|-------|------|-------------|---------|----------|
| **A: Cost-Optimized** | 70B FP8 | 2x H100 | FP8 quantization, TP=2 | ~$5.38 | Dev/test, low-traffic |
| **B: Latency-Optimized** | 70B + EAGLE3 | 4x H100 | Speculative decoding | ~$10.76 | Interactive, chat |
| **C: Throughput-Optimized** | 70B | 8x H100 | DP=4, high concurrency | ~$21.52 | Batch, high-volume |
| **D: Enterprise-Scale** | 70B Disagg | 16x H100 | Disaggregated P/D | ~$43.04 | SLA-bound production |
| **E: Maximum Scale** | 405B FP8 | 16x H100 (2 nodes) | Multi-node PP=2 | ~$43.04 | Frontier model serving |

*Cost estimates based on on-demand H100 SXM pricing at ~$2.69/GPU/hr.*

---

## Profile A: Cost-Optimized (2x H100, FP8)

**Directory**: `llama-70b-fp8-tp2/`

Deploys Llama 3.1 70B with FP8 quantization on 2 GPUs. FP8 halves the memory footprint, allowing the 70B model to fit on just 2 H100s with TP=2.

**Configuration**:
- Model: `meta-llama/Llama-3.1-70B-Instruct-FP8`
- Tensor Parallelism: TP=2
- Quantization: Native FP8 (H100 FP8 tensor cores)
- GPU Memory Utilization: 0.92
- Max Context Length: 4096 tokens
- Prefix Caching: Enabled

**Best for**: Development environments, staging, low-traffic production workloads, cost-sensitive deployments where moderate latency is acceptable.

**Deploy**:
```bash
kubectl apply -k inference/vllm/profiles/llama-70b-fp8-tp2/
```

---

## Profile B: Latency-Optimized (4x H100, EAGLE3)

**Directory**: `llama-70b-eagle3/`

Uses EAGLE3 speculative decoding to achieve 2-4x lower inter-token latency. A small draft model proposes multiple tokens that the main model verifies in a single forward pass.

**Configuration**:
- Model: `meta-llama/Llama-3.1-70B-Instruct`
- Draft Model: EAGLE3 draft head
- Tensor Parallelism: TP=4
- Speculative Tokens: 5 per step
- Acceptance Rate: ~70-85% typical
- Max Context Length: 8192 tokens

**Best for**: Real-time chat, interactive applications, voice AI backends, any use case where perceived response speed is critical.

**Deploy**:
```bash
kubectl apply -k inference/vllm/profiles/llama-70b-eagle3/
```

---

## Profile C: Throughput-Optimized (8x H100, DP=4)

**Directory**: `llama-70b-tp4/`

Maximizes throughput with data parallelism (4 independent TP=2 replicas on 8 GPUs). Each replica handles requests independently, providing linear throughput scaling.

**Configuration**:
- Model: `meta-llama/Llama-3.1-70B-Instruct`
- Tensor Parallelism: TP=2 per replica
- Data Parallelism: DP=4 (4 replicas)
- Max Batch Size: 256 sequences per replica
- Max Context Length: 8192 tokens
- Chunked Prefill: Enabled

**Best for**: Batch processing, high-volume API serving, offline evaluation, any workload where throughput matters more than per-request latency.

**Deploy**:
```bash
kubectl apply -k inference/vllm/profiles/llama-70b-tp4/
```

---

## Profile D: Enterprise-Scale (16 GPUs, Disaggregated P/D)

**Directory**: `llama-70b-disagg-pd/`

Disaggregated prefill/decode architecture separates the compute-bound prefill phase from the memory-bound decode phase onto dedicated GPU pools. This eliminates interference between the two phases and allows independent scaling.

**Configuration**:
- Model: `meta-llama/Llama-3.1-70B-Instruct`
- Prefill Pool: 8x H100, TP=4, optimized for compute
- Decode Pool: 8x H100, TP=4, optimized for memory bandwidth
- KV-Cache Transfer: NCCL or NIXL between pools
- Independent Autoscaling: VariantAutoscaler for each pool

**Best for**: Production workloads with strict SLAs, mixed traffic patterns (some users send long prompts, others have long conversations), enterprise deployments requiring predictable performance.

**Deploy**:
```bash
kubectl apply -k inference/vllm/profiles/llama-70b-disagg-pd/
```

---

## Profile E: Maximum Scale (405B, 16 GPUs Multi-Node)

**Directory**: `llama-405b-multinode/`

Deploys the full Llama 3.1 405B model across 2 physical nodes using LeaderWorkerSet and Ray for distributed coordination. Pipeline parallelism splits the model across nodes while tensor parallelism parallelizes within each node.

**Configuration**:
- Model: `meta-llama/Llama-3.1-405B-Instruct-FP8`
- Tensor Parallelism: TP=8 per node (NVLink/NVSwitch)
- Pipeline Parallelism: PP=2 across nodes (InfiniBand)
- KV-Cache Dtype: FP8 for maximum capacity
- GPU Memory Utilization: 0.95
- Max Context Length: 8192 tokens
- Requires: LeaderWorkerSet CRD, InfiniBand networking

**Best for**: Applications requiring frontier model capabilities (complex reasoning, code generation, multi-step analysis), research, and evaluation.

**Deploy**:
```bash
kubectl apply -k inference/vllm/profiles/llama-405b-multinode/
```

---

## Decision Guide

Use this flowchart to select the right profile:

```
Start
  │
  ├─ Budget constrained? ──────────────────────────── Profile A ($5.38/hr)
  │
  ├─ Need lowest latency? (chat, voice)
  │    └─ Yes ──────────────────────────────────────── Profile B ($10.76/hr)
  │
  ├─ Need highest throughput? (batch, high-volume)
  │    └─ Yes ──────────────────────────────────────── Profile C ($21.52/hr)
  │
  ├─ Need SLA guarantees + mixed traffic?
  │    └─ Yes ──────────────────────────────────────── Profile D ($43.04/hr)
  │
  └─ Need 405B model capabilities?
       └─ Yes ──────────────────────────────────────── Profile E ($43.04/hr)
```

### Key Trade-offs

| Dimension | Best Profile | Trade-off |
|-----------|-------------|-----------|
| Lowest cost | A | Higher latency, lower throughput |
| Lowest latency | B | Moderate cost, EAGLE3 overhead on throughput |
| Highest throughput | C | Higher cost, moderate latency |
| Best SLA | D | Highest complexity, requires disaggregated setup |
| Largest model | E | Requires multi-node, InfiniBand, highest cost |

### Scaling Path

A typical scaling journey:

1. **Start with Profile A** for development and testing
2. **Move to Profile B** when user-facing latency matters
3. **Scale to Profile C** when traffic grows beyond single-replica capacity
4. **Upgrade to Profile D** when SLA requirements tighten and traffic patterns are mixed
5. **Deploy Profile E** when 70B model capability is insufficient

## Common Operations

### Check deployment status
```bash
# List all vLLM deployments
kubectl get deployments -n inference -l app.kubernetes.io/component=inference-engine

# Check GPU utilization
kubectl exec -n inference <pod-name> -- nvidia-smi

# View vLLM metrics
kubectl port-forward svc/<service-name> -n inference 8000:8000
curl http://localhost:8000/metrics
```

### Scale a profile
```bash
# Scale Profile C replicas
kubectl scale deployment vllm-70b-tp4 -n inference --replicas=8
```

### Switch profiles
```bash
# Remove current profile
kubectl delete -k inference/vllm/profiles/llama-70b-fp8-tp2/

# Deploy new profile
kubectl apply -k inference/vllm/profiles/llama-70b-eagle3/
```
