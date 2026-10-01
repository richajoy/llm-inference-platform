# Troubleshooting Guide

## GPU Issues

### GPU Not Detected by Kubernetes

**Symptoms:**
- `kubectl describe node` shows `nvidia.com/gpu: 0`
- Pods stuck in `Pending` with "Insufficient nvidia.com/gpu"

**Diagnosis:**
```bash
# Check if GPUs are visible at OS level
nvidia-smi

# Check GPU Operator pods
kubectl get pods -n gpu-operator

# Check device plugin logs
kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset

# Check container runtime
crictl info | jq '.config.containerd.defaultRuntime'
```

**Fixes:**

1. **NVIDIA driver not loaded:**
   ```bash
   # Check driver
   nvidia-smi
   # If not found, the GPU Operator should install drivers
   kubectl rollout restart daemonset -n gpu-operator nvidia-driver-daemonset
   ```

2. **Container runtime not configured:**
   ```bash
   # For k3s, check /etc/rancher/k3s/config.yaml
   cat /etc/rancher/k3s/config.yaml
   # Should contain nvidia runtime configuration
   ```

3. **GPU Operator not installed:**
   ```bash
   make install-gpu-operator
   ```

4. **Device plugin crashlooping:**
   ```bash
   kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset --previous
   # Often caused by driver version mismatch
   ```

### CUDA Out of Memory (OOM)

**Symptoms:**
- vLLM pod crashes with `torch.cuda.OutOfMemoryError`
- Logs show "CUDA error: out of memory"

**Diagnosis:**
```bash
# Check current GPU memory usage
nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv

# Check vLLM logs for memory allocation
kubectl logs -n inference <vllm-pod> | grep -i "memory\|oom\|error"
```

**Fixes:**

1. **Reduce max-model-len:**
   ```yaml
   args:
     - "--max-model-len=4096"    # Reduce from 8192
   ```
   Shorter context reduces KV cache memory. Each halving of context length reduces KV cache by half.

2. **Reduce gpu-memory-utilization:**
   ```yaml
   args:
     - "--gpu-memory-utilization=0.85"    # Reduce from 0.90
   ```
   Leaves more headroom for CUDA allocations and fragmentation.

3. **Use FP8 quantization:**
   ```yaml
   args:
     - "--quantization=fp8"
     - "--kv-cache-dtype=fp8"
   ```
   Halves model size and KV cache memory.

4. **Increase tensor parallelism:** Split the model across more GPUs.

5. **Reduce max_num_seqs:** Limit concurrent sequences to reduce KV cache pressure.
   ```yaml
   args:
     - "--max-num-seqs=128"    # Reduce from 256
   ```

### MIG Not Working

**Symptoms:**
- `nvidia-smi mig -lgi` shows no instances
- MIG manager pod stuck or crashlooping

**Diagnosis:**
```bash
# Check MIG manager logs
kubectl logs -n gpu-operator -l app=nvidia-mig-manager

# Check node label
kubectl get node -o jsonpath='{.items[0].metadata.labels}' | jq '."nvidia.com/mig.config"'

# Check driver version (MIG requires driver >= 470)
nvidia-smi --query-gpu=driver_version --format=csv
```

**Fixes:**

1. **Driver version too old:** MIG requires NVIDIA driver >= 470. The GPU Operator should install a compatible version.

2. **GPU needs reset after MIG config change:**
   ```bash
   # The MIG manager should handle this, but manually:
   nvidia-smi -mig 1    # Enable MIG mode (requires GPU reset)
   # Pods on the GPU must be drained first
   ```

3. **Incorrect MIG profile label:**
   ```bash
   # Check available profiles
   ls platform/gpu-operator/mig-profiles/

   # Apply correct label
   kubectl label node <node> nvidia.com/mig.config=all-1g-10gb --overwrite
   ```

4. **MIG manager pod restarting:**
   ```bash
   # Delete and let it recreate
   kubectl delete pod -n gpu-operator -l app=nvidia-mig-manager
   ```

## vLLM Issues

### High TTFT (Time to First Token)

**Symptoms:**
- TTFT > 1s for short prompts
- Users experience slow initial response

**Diagnosis:**
```bash
# Check vLLM metrics
curl http://<vllm-service>:8000/metrics | grep "vllm:time_to_first_token"

# Check queue depth
curl http://<vllm-service>:8000/metrics | grep "vllm:num_requests_waiting"

# Check if prefix caching is enabled
kubectl logs -n inference <vllm-pod> | grep "prefix"
```

**Fixes:**

1. **Enable prefix caching:**
   ```yaml
   args:
     - "--enable-prefix-caching"
   ```
   Reuses KV cache from identical prompt prefixes. Critical for systems with shared system prompts.

2. **Enable chunked prefill:**
   ```yaml
   args:
     - "--enable-chunked-prefill"
   ```
   Prevents long prefills from blocking decode steps.

3. **Check queue depth:** If `num_requests_waiting` is consistently > 0, the system is overloaded. Scale up vLLM replicas or reduce request rate.

4. **Reduce max-model-len:** Smaller context windows speed up attention computation.

5. **Use EAGLE3 speculative decoding:** While primarily reducing ITL, it can also reduce perceived TTFT for streaming.

### KV-Cache Full / Preemptions

**Symptoms:**
- vLLM logs show "Preempting requests"
- Increased latency spikes
- Dropped requests under load

**Diagnosis:**
```bash
# Check preemption events
kubectl logs -n inference <vllm-pod> | grep -i "preempt"

# Check KV cache utilization
curl http://<vllm-service>:8000/metrics | grep "vllm:gpu_cache_usage_perc"

# Check number of running sequences
curl http://<vllm-service>:8000/metrics | grep "vllm:num_requests_running"
```

**Fixes:**

1. **Reduce max_num_seqs:**
   ```yaml
   args:
     - "--max-num-seqs=64"    # Limit concurrent sequences
   ```

2. **Reduce max-model-len:** Each sequence's KV cache is proportional to context length.

3. **Use FP8 KV cache:**
   ```yaml
   args:
     - "--kv-cache-dtype=fp8"
   ```
   Halves KV cache memory, doubling the number of concurrent sequences.

4. **Scale horizontally:** Add more vLLM replicas behind a load balancer.

### vLLM Pod Not Starting

**Symptoms:**
- Pod stuck in `ContainerCreating` or `CrashLoopBackOff`

**Diagnosis:**
```bash
# Check pod events
kubectl describe pod -n inference <pod-name>

# Check pod logs
kubectl logs -n inference <pod-name>

# Check if model exists on PVC
kubectl exec -n inference <pod-name> -- ls -la /models/meta-llama/
```

**Common causes:**

1. **Model not downloaded:** Run `make download-models` first.
2. **Insufficient GPU memory:** Check if the model fits. See MIG sizing guide.
3. **PVC not mounted:** Check PVC status with `kubectl get pvc -n inference`.
4. **Image pull failure:** Check that `vllm/vllm-openai:v0.8.5` is accessible.
5. **GPU resource not available:** Check `kubectl describe node` for available GPUs.

## Network Issues

### InfiniBand Not Connecting (Multi-Node)

**Symptoms:**
- NCCL initialization hangs
- vLLM multi-node deployment fails to start
- Logs show "NCCL timeout" or "Socket connection refused"

**Diagnosis:**
```bash
# Check InfiniBand devices
ibstat

# Check NCCL debug output (set in deployment)
# NCCL_DEBUG=INFO

# Check Network Operator pods
kubectl get pods -n network-operator

# Check NIC Cluster Policy
kubectl get nicclusterpolicies
```

**Fixes:**

1. **Set correct NCCL environment variables:**
   ```yaml
   env:
     - name: NCCL_IB_DISABLE
       value: "0"
     - name: NCCL_IB_HCA
       value: "mlx5"
     - name: NCCL_SOCKET_IFNAME
       value: "eth0"
     - name: NCCL_NET_GDR_LEVEL
       value: "PIX"
   ```

2. **Install Network Operator:**
   ```bash
   make install-network-operator
   ```

3. **Check SR-IOV device plugin:**
   ```bash
   kubectl get pods -n network-operator -l app=sriov-device-plugin
   ```

4. **Verify GPUDirect RDMA:**
   ```bash
   # On the node
   nvidia-smi topo -m
   # Should show "NV#" for NVLink and "PIX" or "SYS" for PCIe
   ```

## Terraform Issues

### State Lock / Stale State

**Symptoms:**
- `terraform apply` fails with "state lock" error
- Resources exist but Terraform wants to recreate them

**Fixes:**

1. **State lock:**
   ```bash
   # Force unlock (use with caution)
   terraform force-unlock <lock-id>
   ```

2. **Import existing resources:**
   ```bash
   terraform import <resource_address> <resource_id>
   ```

3. **Refresh state:**
   ```bash
   terraform refresh
   ```

### RunPod Terraform Provider Issues

**Symptoms:**
- Provider not found or version mismatch

**Fixes:**
```bash
cd infra/terraform/runpod
rm -rf .terraform .terraform.lock.hcl
terraform init
```

## Pod Scheduling Issues

### Pods Stuck in Pending

**Diagnosis:**
```bash
kubectl describe pod <pod-name> -n <namespace>
# Look at "Events" section for scheduling failures
```

**Common causes and fixes:**

1. **Insufficient GPU resources:**
   ```bash
   kubectl describe node <node> | grep -A5 "Allocated resources"
   ```
   Solution: Free up GPUs or scale down other deployments.

2. **Node affinity/taint issues:**
   ```bash
   kubectl get nodes --show-labels
   kubectl describe node <node> | grep Taints
   ```

3. **PVC not bound:**
   ```bash
   kubectl get pvc -n <namespace>
   # If Pending, check StorageClass
   kubectl get sc
   ```

4. **Resource requests too high:**
   Check that CPU/memory requests don't exceed node capacity.

## Model Download Issues

### Download Job Fails

**Symptoms:**
- Job status shows Failed
- Pod logs show authentication or network errors

**Diagnosis:**
```bash
kubectl logs -n inference job/model-download
```

**Fixes:**

1. **HuggingFace token invalid:**
   ```bash
   # Verify token
   curl -H "Authorization: Bearer $HF_TOKEN" https://huggingface.co/api/whoami

   # Update secret
   kubectl delete secret hf-token -n inference
   kubectl create secret generic hf-token -n inference --from-literal=token=$HF_TOKEN
   ```

2. **Gated model access not granted:**
   - Visit the model page on HuggingFace
   - Accept the license agreement
   - Wait for approval

3. **Insufficient disk space:**
   ```bash
   kubectl exec -n inference <pod> -- df -h /models
   ```
   The PVC needs at least 500 GB for all models. Increase PVC size if needed.

4. **Network timeout:**
   ```bash
   # Retry the download job
   kubectl delete job model-download -n inference
   kubectl apply -f inference/model-cache/download-job.yaml
   ```

## Enterprise Services Issues

### LiteLLM Can't Connect to PostgreSQL

**Symptoms:**
- LiteLLM pod crashlooping
- Logs show "connection refused" to PostgreSQL

**Fixes:**
```bash
# Check PostgreSQL pod
kubectl get pods -n enterprise -l app=postgres

# Check PostgreSQL logs
kubectl logs -n enterprise -l app=postgres

# Verify service
kubectl get svc -n enterprise postgres

# Test connectivity from LiteLLM pod
kubectl exec -n enterprise <litellm-pod> -- pg_isready -h postgres -p 5432
```

### LiteLLM Rate Limiting Not Working

**Fixes:**
```bash
# Check Redis
kubectl get pods -n enterprise -l app=redis
kubectl exec -n enterprise <redis-pod> -- redis-cli ping
# Should return PONG

# Check LiteLLM config has Redis configured
kubectl get configmap -n enterprise litellm-config -o yaml | grep redis
```

## Quick Diagnostic Commands

```bash
# Full system health check
make status-all

# GPU health
nvidia-smi
nvidia-smi mig -lgi    # If MIG enabled

# Kubernetes health
kubectl get nodes
kubectl get pods -A | grep -v Running | grep -v Completed

# vLLM health
kubectl logs -n inference -l app=vllm --tail=50
curl http://<vllm-svc>:8000/health

# LiteLLM health
curl http://<litellm-svc>:4000/health

# Metrics health
curl http://<prometheus-svc>:9090/-/healthy

# Resource usage
kubectl top nodes
kubectl top pods -n inference
```
