# Ray for Distributed LLM Inference

## Overview

vLLM uses [Ray](https://docs.ray.io/) internally for multi-node tensor parallelism (TP) and pipeline parallelism (PP). When a model is too large for a single node (e.g., Llama 405B needs 16 GPUs), Ray coordinates the distributed execution across multiple GPU nodes.

## Why Ray?

```
┌──────────────────────────────────────────────────────────────┐
│                        Ray Cluster                            │
│                                                               │
│  ┌─────────────────────┐      ┌─────────────────────┐       │
│  │   Head Node          │      │   Worker Node        │       │
│  │   8x H100 SXM        │◄─IB─►│   8x H100 SXM        │       │
│  │                      │      │                      │       │
│  │  ┌────────────────┐ │      │  ┌────────────────┐ │       │
│  │  │ Ray GCS Server  │ │      │  │ Ray Worker      │ │       │
│  │  │ Ray Dashboard   │ │      │  │ Joins cluster   │ │       │
│  │  │ vLLM API Server │ │      │  │ Runs GPU tasks  │ │       │
│  │  └────────────────┘ │      │  └────────────────┘ │       │
│  │                      │      │                      │       │
│  │  PP Stage 0 (TP=8)  │      │  PP Stage 1 (TP=8)  │       │
│  │  Layers 0-39         │      │  Layers 40-79        │       │
│  └─────────────────────┘      └─────────────────────┘       │
│                                                               │
│  NCCL: InfiniBand (GPUDirect RDMA) for all-reduce            │
│  Ray: Process management, scheduling, fault tolerance         │
└──────────────────────────────────────────────────────────────┘
```

**Ray handles**: Process lifecycle, cluster formation, task scheduling, fault detection, dashboard
**NCCL handles**: GPU-to-GPU tensor communication (all-reduce for TP, point-to-point for PP)
**vLLM handles**: Model loading, KV-cache management, batching, API serving

## Deployment Approaches

### Approach 1: LeaderWorkerSet (Simple, Dev/Testing)

```yaml
# Uses K8s LeaderWorkerSet CRD
# Inlines `ray start` in pod commands
# Simple but fragile - no auto-recovery
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
spec:
  leaderWorkerTemplate:
    leaderTemplate:
      spec:
        containers:
        - command: ["bash", "-c", "ray start --head && vllm serve ..."]
    workerTemplate:
      spec:
        containers:
        - command: ["bash", "-c", "ray start --address=$HEAD && sleep infinity"]
```

**Pros**: No extra operator, straightforward
**Cons**: Bash-driven lifecycle, no auto-recovery, no Ray dashboard, no autoscaling
**Use for**: Development, quick testing, single-use clusters

### Approach 2: KubeRay Operator (Production)

```yaml
# Uses KubeRay RayCluster CRD
# Operator manages Ray lifecycle natively
# Auto-recovery, dashboard, autoscaling
apiVersion: ray.io/v1
kind: RayCluster
spec:
  headGroupSpec:
    rayStartParams:
      num-gpus: "8"
  workerGroupSpecs:
    - replicas: 1
      maxReplicas: 3
      rayStartParams:
        num-gpus: "8"
```

**Pros**: K8s-native lifecycle, auto-recovery, Ray dashboard, worker autoscaling, gang scheduling
**Cons**: Requires KubeRay operator installation
**Use for**: Production, long-running clusters, multi-tenant environments

### Decision Matrix

| Criteria | LeaderWorkerSet | KubeRay |
|----------|----------------|---------|
| Setup complexity | Low | Medium (operator install) |
| Auto-recovery | No | Yes (restarts failed workers) |
| Ray Dashboard | Manual port-forward | Built-in service |
| Worker autoscaling | No | Yes (Ray autoscaler) |
| Gang scheduling | No | Yes (with Volcano/Yunikorn) |
| Fault tolerance | Pod restart only | Ray-level recovery |
| Observability | kubectl logs | Dashboard + Prometheus metrics |
| **Recommendation** | **Dev/testing** | **Production** |

## KubeRay Installation

```bash
# Install operator
make install-ray-operator

# Or manually:
helm repo add kuberay https://ray-project.github.io/kuberay-helm/
helm install kuberay-operator kuberay/kuberay-operator \
  --namespace kuberay-system --create-namespace \
  --version 1.3.0
```

## Deploying vLLM on RayCluster

```bash
# Deploy RayCluster + vLLM for 405B
kubectl apply -f inference/vllm/profiles/llama-405b-multinode/ray-cluster.yaml

# Monitor cluster formation
kubectl get raycluster -n inference
kubectl port-forward svc/vllm-405b-ray 8265:8265 -n inference
# Open http://localhost:8265 for Ray Dashboard

# Check GPU availability
kubectl exec -n inference -l role=head -- \
  python3 -c "import ray; ray.init(address='auto'); print(ray.cluster_resources())"

# Test inference
curl http://vllm-405b-ray.inference:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"meta-llama/Llama-3.1-405B-Instruct-FP8","messages":[{"role":"user","content":"Hello"}]}'
```

## Key NCCL Environment Variables

These must be identical on head and all workers for InfiniBand communication:

| Variable | Value | Purpose |
|----------|-------|---------|
| `NCCL_IB_DISABLE` | `0` | Enable InfiniBand |
| `NCCL_NET_GDR_LEVEL` | `5` | GPUDirect RDMA (bypass CPU) |
| `NCCL_IB_HCA` | `mlx5` | Mellanox ConnectX HCA device |
| `NCCL_SOCKET_NTHREADS` | `8` | Socket threads for comms |
| `NCCL_IB_QPS_PER_CONNECTION` | `4` | Queue pairs per IB connection |
| `NCCL_IB_GID_INDEX` | `3` | GID index for RoCE v2 |
| `NCCL_IB_TIMEOUT` | `22` | IB timeout (~4 min) |
| `NCCL_IB_RETRY_CNT` | `7` | IB retry count |

## Scaling Patterns

### Pattern 1: Fixed Cluster (TP=8, PP=2)
```
Head:   8 GPUs (TP=8, PP stage 0)
Worker: 8 GPUs (TP=8, PP stage 1)
Total:  16 GPUs, fixed
```

### Pattern 2: Elastic Workers (Future)
```
Head:   8 GPUs (always running)
Workers: 1-3 nodes (autoscaled by Ray)
  - Scale up: pending inference requests > threshold
  - Scale down: idle workers for 5+ minutes
```

Note: Elastic PP is not yet supported in vLLM (as of v0.8.x). The worker count must match `pipeline-parallel-size` at model load time. Elastic scaling currently applies to data-parallel replicas, not PP stages.

### Pattern 3: Multi-Model on Shared Ray Cluster
```
RayCluster (16 GPUs across 2 nodes)
  ├── vLLM 405B (TP=8, PP=2) → uses all 16 GPUs
  └── OR: vLLM 70B (TP=4) × 4 replicas → 4 GPUs each
```

Ray's resource management ensures GPU isolation between models.

## Troubleshooting

### Worker not joining cluster
```bash
# Check worker logs
kubectl logs -l role=worker -n inference --tail=50

# Check Ray GCS connectivity
kubectl exec -l role=worker -n inference -- \
  ray status --address=<head-pod-ip>:6379

# Common fix: ensure head service DNS resolves
kubectl exec -l role=worker -n inference -- \
  nslookup vllm-405b-ray-head-svc.inference.svc.cluster.local
```

### NCCL timeout during model loading
```bash
# Enable NCCL debug logging
kubectl set env deployment/vllm-405b NCCL_DEBUG=INFO -n inference

# Check InfiniBand connectivity
kubectl exec -l role=head -n inference -- ibstat
kubectl exec -l role=worker -n inference -- ibstat

# Verify GPUDirect RDMA
kubectl exec -l role=head -n inference -- \
  python3 -c "import torch; print(torch.cuda.is_available()); print(torch.cuda.device_count())"
```

### Ray Dashboard not accessible
```bash
kubectl port-forward svc/vllm-405b-ray 8265:8265 -n inference
# Open http://localhost:8265
```
