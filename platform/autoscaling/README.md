# Event-Driven Autoscaling for LLM Inference

## Why KEDA for LLM Inference?

Traditional Kubernetes HPA falls short for LLM workloads because:

1. **CPU/memory metrics are meaningless** for GPU inference — a vLLM pod at 5% CPU can be fully saturated on GPU memory bandwidth
2. **Custom metrics require Prometheus Adapter** — an extra component to install, configure, and maintain
3. **No activation thresholds** — HPA can't distinguish "no traffic" from "low traffic"
4. **No scale-to-zero** — wasted GPU cost during idle periods
5. **Single metric type** — HPA picks the metric that requires the most replicas; you can't compose triggers with different behaviors

**KEDA solves all of these** by querying Prometheus directly, supporting cron schedules, scale-to-zero with keepalive, and composing multiple independent triggers.

## Evaluation: KEDA vs HPA vs llm-d VariantAutoscaler

| Capability | HPA + Adapter | KEDA | llm-d VariantAutoscaler |
|-----------|:---:|:---:|:---:|
| Custom Prometheus metrics | Via adapter | Direct queries | Via CRD |
| Scale-to-zero | No | Yes | No |
| Cron-based scheduling | No | Yes | No |
| Activation thresholds | No | Yes | N/A |
| Fallback replicas | No | Yes | No |
| Multiple trigger types | Limited | Unlimited | Metric-only |
| P/D independent scaling | No | Manual (2 ScaledObjects) | Native |
| Sequence-length awareness | No | No | Yes |
| Setup complexity | Medium (adapter) | Low (operator only) | Medium (llm-d) |
| **Best for** | **Simple setups** | **Production general** | **Disaggregated P/D** |

**Recommendation**: Use **KEDA** as the default autoscaler. Add **llm-d VariantAutoscaler** only for disaggregated prefill/decode workloads where sequence-length-aware scaling matters.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                     Autoscaling Architecture                      │
│                                                                   │
│   ┌───────────────┐    ┌───────────────────────────────────────┐ │
│   │  Prometheus    │    │  KEDA Operator                        │ │
│   │  (monitoring)  │◄───│  Polls every 15s                      │ │
│   │                │    │  Evaluates 6 triggers:                │ │
│   │  vLLM metrics: │    │    TTFT P99, ITL P99, E2E P99,       │ │
│   │  - TTFT        │    │    Queue depth, KV-cache, Batch size  │ │
│   │  - ITL/TPOT    │    │                                       │ │
│   │  - Queue depth │    │  Creates/manages HPA automatically    │ │
│   │  - KV-cache %  │    └────────────────┬──────────────────────┘ │
│   │  - Batch size  │                     │                        │
│   │  - E2E latency │                     ▼                        │
│   └───────────────┘    ┌───────────────────────────────────────┐ │
│                         │  Kubernetes HPA (KEDA-managed)        │ │
│                         │  Scale policies:                      │ │
│                         │    Up:   +2 pods / 120s, 60s stab.   │ │
│                         │    Down: -1 pod / 300s, 300s stab.   │ │
│                         └────────────────┬──────────────────────┘ │
│                                          │                        │
│                                          ▼                        │
│   ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐            │
│   │vLLM 1│  │vLLM 2│  │vLLM 3│  │ ...  │  │vLLM N│            │
│   │4xGPU │  │4xGPU │  │4xGPU │  │      │  │4xGPU │            │
│   └──────┘  └──────┘  └──────┘  └──────┘  └──────┘            │
│   min: 1                                        max: 8          │
└──────────────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# 1. Install KEDA operator
make install-keda

# 2. Apply ScaledObjects for all vLLM profiles
make install-keda-objects

# 3. Verify
kubectl get scaledobjects -n inference
kubectl get hpa -n inference
```

## Scaling Configurations

### Option A: KEDA Event-Driven (Recommended)

| File | Target | Triggers | Use Case |
|------|--------|----------|----------|
| `keda-vllm.yaml` | 70B TP=4 | 6 (TTFT, ITL, E2E, queue, KV-cache, batch) | Production baseline |
| `keda-profiles/llama-8b-mig.yaml` | 8B MIG | 3 (TTFT, queue, KV-cache) | MIG slice workloads |
| `keda-profiles/llama-70b-fp8-tp2.yaml` | 70B FP8 | 4 (TTFT, ITL, queue, KV-cache) | Cost-optimized |
| `keda-profiles/llama-70b-disagg-pd.yaml` | P/D pools | 2+3 (per pool) | Disaggregated serving |
| `keda-cron.yaml` | 70B TP=4 | Cron + metrics | Predictable traffic |
| `keda-scale-to-zero.yaml` | 70B TP=4 | Keepalive + queue | Dev/staging cost savings |

### Option B: HPA with Prometheus Adapter

```bash
# Install Prometheus Adapter
make install-prometheus-adapter

# Apply HPA
kubectl apply -f platform/autoscaling/hpa-vllm.yaml
```

### Option C: llm-d VariantAutoscaler (P/D only)

```bash
# Apply VariantAutoscaler for disaggregated prefill/decode
kubectl apply -f inference/llm-d/autoscaler/variant-autoscaler.yaml
```

## Scaling Metrics Deep Dive

### Tier 1: SLO Metrics (Latency)

| Metric | PromQL | Threshold | Why |
|--------|--------|-----------|-----|
| **P99 TTFT** | `histogram_quantile(0.99, sum(rate(vllm:time_to_first_token_seconds_bucket[5m])) by (le))` | 3s | Prefill latency — first token delivery SLO |
| **P99 ITL/TPOT** | `histogram_quantile(0.99, sum(rate(vllm:time_per_output_token_seconds_bucket[5m])) by (le))` | 100ms | Decode latency — streaming experience SLO |
| **P99 E2E** | `histogram_quantile(0.99, sum(rate(vllm:e2e_request_latency_seconds_bucket[5m])) by (le))` | 30s | Overall request latency SLO |

### Tier 2: Capacity Metrics (Saturation)

| Metric | PromQL | Threshold | Why |
|--------|--------|-----------|-----|
| **Queue depth** | `sum(vllm:num_requests_waiting)` | 10 | Requests waiting = capacity exhausted |
| **KV-cache usage** | `avg(vllm:gpu_cache_usage_perc)` | 85% | Near 95% causes preemptions (cascade failure) |
| **Batch size** | `avg(vllm:num_requests_running)` | 64 | Approaching max-num-seqs = memory-bound |

### Tier 3: Infrastructure Metrics (Fallback)

| Metric | PromQL | Threshold | Why |
|--------|--------|-----------|-----|
| **GPU utilization** | `avg(DCGM_FI_DEV_GPU_UTIL)` | 80% | General GPU saturation signal |
| **GPU memory** | `avg(DCGM_FI_DEV_MEM_COPY_UTIL)` | 80% | Memory bandwidth saturation |

## Scaling Patterns

### Pattern 1: Always-On Production (Default)

```yaml
minReplicaCount: 1     # Always have at least 1 replica warm
maxReplicaCount: 8     # Scale up to 8 replicas
cooldownPeriod: 300    # 5 min before scaling down
```

Best for: Production workloads requiring low-latency responses.

### Pattern 2: Scale-to-Zero (Cost Optimization)

```yaml
minReplicaCount: 0     # Allow scaling to zero
idleReplicaCount: 0    # Target 0 when idle
cooldownPeriod: 600    # 10 min before zero (allow stragglers)
```

Uses a keepalive trigger to detect ANY traffic and prevent premature zero-scaling. See `keda-scale-to-zero.yaml`.

Best for: Dev/staging, batch workloads, off-hours cost savings.

### Pattern 3: Cron + Metric Hybrid

```yaml
triggers:
  - type: cron           # Set floor: 3 replicas during business hours
  - type: prometheus     # Scale above floor based on actual demand
```

Cron pre-warms replicas before traffic arrives, eliminating cold-start during morning ramp-up. See `keda-cron.yaml`.

Best for: Enterprise workloads with predictable daily patterns.

### Pattern 4: Independent P/D Scaling

Separate ScaledObjects for prefill and decode pools:
- **Prefill**: Scale on TTFT + queue depth (compute-bound)
- **Decode**: Scale on ITL/TPOT + KV-cache (memory-bound)

See `keda-profiles/llama-70b-disagg-pd.yaml`.

Best for: Disaggregated prefill/decode deployments.

## Scaling Behavior Tuning

### Why Conservative Scale-Down?

GPU pods take 2-5 minutes to load models. Premature scale-down means:
1. Pod terminates, GPU memory freed
2. New request arrives, triggers scale-up
3. New pod starts, downloads/loads model (2-5 min)
4. Users experience timeout during this window

Therefore: **scale up fast, scale down slow**.

### Scale-Up Policy
```yaml
scaleUp:
  stabilizationWindowSeconds: 60    # React within 1 min
  policies:
    - type: Pods
      value: 2                       # Add max 2 pods at a time
      periodSeconds: 120             # Every 2 minutes
```

### Scale-Down Policy
```yaml
scaleDown:
  stabilizationWindowSeconds: 300   # Wait 5 min before reducing
  policies:
    - type: Pods
      value: 1                       # Remove max 1 pod
      periodSeconds: 300             # Every 5 minutes
    - type: Percent
      value: 25                      # Or max 25% reduction
      periodSeconds: 300
  selectPolicy: Min                  # Use most conservative policy
```

### Fallback Behavior
```yaml
fallback:
  failureThreshold: 5     # After 5 failed metric fetches
  replicas: 2              # Maintain 2 replicas (don't scale to 0)
```

Prevents catastrophic scale-down when Prometheus is unreachable.

## Customizing Thresholds Per Model

| Model | TTFT P99 | ITL P99 | Queue | KV-Cache | Rationale |
|-------|----------|---------|-------|----------|-----------|
| 8B MIG | 1s | N/A | 20 | 85% | Fast model, higher throughput tolerance |
| 70B TP=4 | 3s | 100ms | 10 | 85% | Baseline production profile |
| 70B FP8 TP=2 | 2s | 80ms | 10 | 85% | FP8 is faster, tighter SLOs |
| 70B Prefill | 2s | N/A | 5 | N/A | Prefill: TTFT-focused |
| 70B Decode | N/A | 50ms | N/A | 80% | Decode: ITL + memory-focused |

## Troubleshooting

### ScaledObject not scaling

```bash
# Check KEDA operator logs
kubectl logs -n keda -l app=keda-operator --tail=50

# Check ScaledObject status
kubectl describe scaledobject vllm-70b-tp4-keda -n inference

# Verify Prometheus connectivity from KEDA
kubectl exec -n keda deploy/keda-operator -- \
  wget -qO- 'http://kube-prometheus-stack-prometheus.monitoring:9090/api/v1/query?query=up'
```

### HPA shows `<unknown>` metrics

```bash
# KEDA creates an HPA — check its status
kubectl get hpa -n inference
kubectl describe hpa keda-hpa-vllm-70b-tp4-keda -n inference

# Check if KEDA metrics server is healthy
kubectl get apiservice v1beta1.external.metrics.k8s.io
```

### Scaling too aggressively or too slowly

Adjust these parameters:
- `pollingInterval`: How often KEDA checks metrics (lower = faster reaction)
- `cooldownPeriod`: How long after last trigger before scaling down
- `stabilizationWindowSeconds`: HPA smoothing window
- `threshold`: Trigger threshold (lower = more sensitive)
- `activationThreshold`: Minimum to start scaling from idle

### Prometheus metrics not found

```bash
# Verify vLLM exposes metrics
kubectl port-forward -n inference svc/vllm-70b-tp4 8000:8000
curl localhost:8000/metrics | grep vllm:num_requests

# Check Prometheus scrape targets
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# Open http://localhost:9090/targets — look for vLLM pods
```

## File Reference

```
platform/autoscaling/
├── README.md                              # This file
├── keda-install.sh                        # KEDA operator installation
├── keda-vllm.yaml                         # Main ScaledObject (70B TP=4, 6 triggers)
├── keda-cron.yaml                         # Cron + metric hybrid pattern
├── keda-scale-to-zero.yaml                # Scale-to-zero pattern (dev/staging)
├── keda-profiles/
│   ├── llama-8b-mig.yaml                  # 8B MIG (fast scaling, higher thresholds)
│   ├── llama-70b-fp8-tp2.yaml             # 70B FP8 (cost-optimized)
│   └── llama-70b-disagg-pd.yaml           # Disaggregated P/D (independent pools)
├── hpa-vllm.yaml                          # Alternative: vanilla HPA (needs adapter)
└── prometheus-adapter/
    └── values.yaml                        # Prometheus Adapter Helm values
```
