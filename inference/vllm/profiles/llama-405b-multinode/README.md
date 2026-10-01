# Llama 3.1 405B Multi-Node Deployment

Deploys `meta-llama/Llama-3.1-405B-Instruct-FP8` across **2 nodes** (16x H100 SXM GPUs) using `LeaderWorkerSet` for coordinated multi-node scheduling.

## Architecture

```
Node 0 (Leader)                   Node 1 (Worker)
┌───────────────────────┐        ┌───────────────────────┐
│ Ray Head + vLLM API   │◄──IB──►│ Ray Worker            │
│ TP=8 (8x H100 SXM)   │        │ TP=8 (8x H100 SXM)   │
│ Pipeline Stage 0      │        │ Pipeline Stage 1      │
└───────────────────────┘        └───────────────────────┘
```

- **Tensor Parallelism**: TP=8 within each node (NVLink/NVSwitch)
- **Pipeline Parallelism**: PP=2 across nodes (InfiniBand)
- **Model Format**: FP8 quantized (native H100 FP8 tensor cores)
- **KV Cache**: FP8 dtype for maximum capacity

## Prerequisites

1. **Hardware**: 2x nodes with 8x H100 SXM GPUs each, InfiniBand ConnectX-7 NICs
2. **LeaderWorkerSet CRD**: Install the LWS controller:
   ```bash
   kubectl apply --server-side -f \
     https://github.com/kubernetes-sigs/lws/releases/latest/download/manifests.yaml
   ```
3. **Network Operator**: NVIDIA Network Operator for InfiniBand/RDMA device plugin
4. **Model Weights**: Pre-downloaded to PVC `model-weights` in namespace `inference`
5. **HuggingFace Token**: Secret `hf-token` with key `token` in namespace `inference`:
   ```bash
   kubectl create secret generic hf-token \
     --namespace inference \
     --from-literal=token=hf_YOUR_TOKEN
   ```

## Deployment

```bash
# Deploy with Kustomize
kubectl apply -k inference/vllm/profiles/llama-405b-multinode/

# Verify LeaderWorkerSet status
kubectl get lws -n inference
kubectl get pods -n inference -l app=vllm-405b

# Watch for both pods to become Ready (takes 10-20 min for model loading)
kubectl wait --for=condition=ready pod -l app=vllm-405b -n inference --timeout=1200s
```

## Validation

```bash
# Check Ray cluster has 16 GPUs
kubectl exec -n inference -l app=vllm-405b,role=head -- ray status

# Test the API endpoint
kubectl port-forward svc/vllm-405b -n inference 8000:8000
curl http://localhost:8000/v1/models
curl http://localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "meta-llama/Llama-3.1-405B-Instruct-FP8", "prompt": "Hello", "max_tokens": 50}'
```

## NCCL Configuration

All NCCL environment variables are set to optimize InfiniBand communication:

| Variable | Value | Purpose |
|----------|-------|---------|
| `NCCL_IB_DISABLE` | `0` | Enable InfiniBand |
| `NCCL_NET_GDR_LEVEL` | `5` | GPU Direct RDMA (full path) |
| `NCCL_IB_HCA` | `mlx5` | Mellanox ConnectX HCA |
| `NCCL_SOCKET_NTHREADS` | `8` | Socket thread count |
| `NCCL_IB_QPS_PER_CONNECTION` | `4` | QPs per connection |
| `NCCL_IB_GID_INDEX` | `3` | RoCEv2 GID index |
| `NCCL_IB_TC` | `136` | Traffic class for DSCP |
| `NCCL_IB_TIMEOUT` | `22` | IB timeout (~134s) |
| `NCCL_IB_RETRY_CNT` | `7` | Max retries on failure |

## Resource Requirements

| Resource | Per Node | Total (2 nodes) |
|----------|----------|-----------------|
| GPU | 8x H100 SXM 80GB | 16x H100 SXM |
| CPU | 16-32 cores | 32-64 cores |
| Memory | 200-256 GiB | 400-512 GiB |
| Shared Memory | 32 GiB | 64 GiB |
| InfiniBand NIC | 1x ConnectX-7 | 2x ConnectX-7 |
| Estimated Cost | ~$21.52/hr | ~$43.04/hr |

## Performance Expectations

| Metric | Expected Value |
|--------|---------------|
| Time to First Token (TTFT) | 500-800ms |
| Inter-Token Latency (ITL) | 30-50ms |
| Throughput | 1500-3000 tokens/sec |
| Max Concurrent Requests | ~32-64 |
| Max Context Length | 8192 tokens |

## Troubleshooting

**Worker not joining Ray cluster**:
- Verify InfiniBand connectivity: `kubectl exec <worker-pod> -- ibstat`
- Check `LWS_LEADER_ADDRESS` env var is set: `kubectl exec <worker-pod> -- env | grep LWS`
- Check Ray logs: `kubectl logs <leader-pod> -n inference | grep -i ray`

**NCCL timeout errors**:
- Verify `nvidia.com/mlnxnics: 1` resource is available on both nodes
- Check Network Operator pods: `kubectl get pods -n nvidia-network-operator`
- Increase `NCCL_IB_TIMEOUT` to `23` for larger clusters

**Out of memory (OOM)**:
- Reduce `--max-model-len` from 8192 to 4096
- Verify `--gpu-memory-utilization 0.95` is appropriate for your GPU memory
- Check that no other workloads are consuming GPU memory on the same nodes
