# Deployment Runbook

Step-by-step guide from zero to production deployment of the Enterprise LLM Inference Platform.

## Prerequisites

### Required Accounts

| Service | Purpose | Required For |
|---------|---------|-------------|
| GPU host (bare metal or any GPU cloud VM) | Single-node dev cluster | Single-node deployment |
| Google Cloud | GKE cluster (prod) | Cloud production |
| HuggingFace | Model weight downloads | All deployments |
| GitHub | Source code | All deployments |

### Required API Keys

```bash
# Copy and fill in your values
cp .env.example .env

# Required keys:
HF_TOKEN=...             # HuggingFace token (read access to gated models)
LITELLM_MASTER_KEY=...   # Master key for LiteLLM admin API
GRAFANA_ADMIN_PASSWORD=... # Grafana login password
```

### Required Tools (Local Machine)

| Tool | Version | Install |
|------|---------|---------|
| terraform | >= 1.5.0 | `brew install terraform` |
| kubectl | >= 1.28 | `brew install kubectl` |
| helm | >= 3.12 | `brew install helm` |
| make | any | Pre-installed on macOS/Linux |
| jq | any | `brew install jq` |

### HuggingFace Model Access

Request access to gated models before starting:
1. Visit huggingface.co/meta-llama/Llama-3.3-70B-Instruct
2. Accept the license agreement
3. Wait for approval (usually instant)
4. Repeat for all models you plan to deploy

## Phase 1: Infrastructure Provisioning

### Option A: Single GPU Node (Development)

Any host with NVIDIA drivers and 8xH100 SXM (or fewer GPUs; the MIG and FP8
profiles fit on 1-2 GPUs) works: bare metal, a colocated server, or a GPU
cloud VM. The platform is provisioned on top of it with k3s.

**Step 1**: Prepare the host:

```bash
# Verify drivers and GPUs
nvidia-smi
# Recommended: 500 GB NVMe for the model cache (see inference/model-cache/pvc.yaml)
```

**Step 2**: SSH into the host:

```bash
ssh <user>@<host-ip>
```

**Step 3**: Install k3s:

```bash
# On the GPU host
make setup-k3s
```

This installs k3s with:
- NVIDIA container runtime pre-configured
- Single-node cluster (all 8 GPUs on one node)
- Default StorageClass for local PVCs
- kubectl and helm installed

**Step 4**: Run post-install setup:

```bash
make setup-post-install
```

This creates namespaces, adds Helm repos, and installs Helm plugins.

**Step 5**: Verify:

```bash
kubectl get nodes
# Should show 1 node in Ready state

nvidia-smi
# Should show 8xH100 GPUs

kubectl get ns
# Should show: inference, enterprise, monitoring, gateway, gpu-operator
```

### Option B: GKE (Production)

**Step 1**: Configure GKE Terraform:

```bash
cd infra/terraform/gke
cp terraform.tfvars.example terraform.tfvars
# Edit with GCP project, region, zone
```

**Step 2**: Apply Terraform:

```bash
terraform init
terraform plan
terraform apply
```

This creates:
- GKE cluster with system node pool
- A3 Ultra GPU node pool (8xH100 per node)
- VPC with InfiniBand subnet
- Required IAM roles

**Step 3**: Get cluster credentials:

```bash
gcloud container clusters get-credentials llm-inference-cluster \
  --zone us-central1-a \
  --project $GCP_PROJECT_ID
```

## Phase 2: Platform Layer

### Step 6: GPU Operator

```bash
# Standard (no MIG)
make install-gpu-operator

# OR with MIG support
make install-gpu-operator-mig
```

Verify:

```bash
# Wait for GPU Operator pods (2-3 minutes)
kubectl get pods -n gpu-operator -w

# All pods should be Running/Completed
kubectl get pods -n gpu-operator

# Verify GPUs are detected
kubectl describe node $(kubectl get nodes -o name | head -1) | grep nvidia.com/gpu
# Expected: nvidia.com/gpu: 8
```

### Step 7: MIG Configuration (Optional)

If using MIG for small model serving:

```bash
# Apply MIG profile (example: all 1g.10gb for max density)
kubectl label node $(kubectl get nodes -o name | head -1 | sed 's|node/||') \
  nvidia.com/mig.config=all-1g-10gb --overwrite

# Wait for MIG manager to reconfigure (1-2 minutes)
kubectl logs -n gpu-operator -l app=nvidia-mig-manager -f

# Verify MIG instances
nvidia-smi mig -lgi
# Should show 56 MIG instances (7 per GPU x 8 GPUs)
```

### Step 8: Monitoring Stack

```bash
make install-monitoring
```

Verify:

```bash
# Check pods
kubectl get pods -n monitoring

# Port-forward Grafana
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

# Access Grafana at http://localhost:3000
# Default credentials: admin / <GRAFANA_ADMIN_PASSWORD from .env>
```

### Step 9: Gateway API

```bash
make install-gateway
```

Verify:

```bash
kubectl get gatewayclass
kubectl get gateway -n gateway
```

## Phase 3: Model Download

### Step 10: Create PVC and Download Models

```bash
make download-models
```

This creates a 500Gi PVC and runs a Job that downloads:
- `meta-llama/Llama-3.1-8B-Instruct`
- `meta-llama/Llama-3.3-70B-Instruct`
- `nvidia/Llama-3.3-70B-Instruct-FP8`
- `yuhuili/EAGLE3-LLaMA3.3-Instruct-70B`
- `meta-llama/Llama-3.1-405B-Instruct` (optional, very large)

Monitor progress:

```bash
# Watch the download job
kubectl logs -n inference job/model-download -f

# Check PVC usage
kubectl exec -n inference job/model-download -- df -h /models
```

The 70B model is ~141 GB and takes approximately 15-30 minutes depending on network speed.

## Phase 4: Inference Deployment

Choose one or more deployment profiles:

### Profile A: Llama 8B on MIG (Quick Start)

```bash
make deploy-8b-mig
```

Verify:

```bash
kubectl get pods -n inference -l profile=llama-8b-mig
kubectl logs -n inference -l profile=llama-8b-mig -f

# Wait for "Uvicorn running" message
# Test with curl
kubectl port-forward -n inference svc/vllm-llama-8b-mig 8000:8000
curl http://localhost:8000/v1/models
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "meta-llama/Llama-3.1-8B-Instruct", "messages": [{"role": "user", "content": "Hello"}], "max_tokens": 50}'
```

### Profile B: Llama 70B TP=4

```bash
make deploy-70b-tp4
```

Requires 4 full GPUs (no MIG). Takes 3-5 minutes to load model weights.

### Profile C: Llama 70B FP8 TP=2

```bash
make deploy-70b-fp8
```

Uses `nvidia/Llama-3.3-70B-Instruct-FP8` pre-quantized model on 2 GPUs.

### Profile D: Llama 70B + EAGLE3

```bash
make deploy-70b-eagle3
```

Requires 4 GPUs. Includes EAGLE3 speculative decoding for lower latency.

### Profile E: Llama 70B Disaggregated P/D

```bash
make deploy-70b-disagg
```

Deploys separate prefill and decode pods with a routing proxy.

## Phase 5: Enterprise Services

### Step 11: LiteLLM Gateway

```bash
make deploy-litellm
```

This deploys:
1. PostgreSQL (for API key/team storage)
2. Redis (for rate limiting)
3. LiteLLM Proxy (the API gateway)

Verify:

```bash
kubectl get pods -n enterprise

# Port-forward LiteLLM
kubectl port-forward -n enterprise svc/litellm 4000:4000

# Test health
curl http://localhost:4000/health

# Test chat (with master key)
curl http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -d '{"model": "llama-70b", "messages": [{"role": "user", "content": "Hello"}], "max_tokens": 50}'
```

### Step 12: Guardrails

```bash
make deploy-guardrails
```

This deploys both LLM Guard (fast input scanning) and NeMo Guardrails (deep safety).

Verify:

```bash
kubectl get pods -n enterprise -l app=llm-guard
kubectl get pods -n enterprise -l app=nemo-guardrails

# Test LLM Guard
kubectl port-forward -n enterprise svc/llm-guard 8060:8060
curl http://localhost:8060/health

# Test NeMo Guardrails
kubectl port-forward -n enterprise svc/nemo-guardrails 8090:8090
curl http://localhost:8090/health
```

## Phase 6: Verification Checklist

Run through this checklist before declaring the deployment production-ready:

### Infrastructure

- [ ] All nodes show `Ready` in `kubectl get nodes`
- [ ] All GPUs detected: `nvidia-smi` shows expected GPU count
- [ ] Namespaces created: `kubectl get ns` shows all 5+ namespaces
- [ ] PVC bound: `kubectl get pvc -n inference` shows `Bound`

### Platform

- [ ] GPU Operator pods all Running: `kubectl get pods -n gpu-operator`
- [ ] DCGM metrics flowing: `curl http://localhost:9090/api/v1/query?query=DCGM_FI_DEV_GPU_UTIL`
- [ ] Grafana accessible with dashboards loaded
- [ ] Prometheus targets all UP: check Prometheus UI targets page

### Inference

- [ ] vLLM pod(s) Running: `kubectl get pods -n inference`
- [ ] Model loaded (check vLLM logs for "Uvicorn running")
- [ ] `/v1/models` returns expected model
- [ ] `/v1/chat/completions` returns valid response
- [ ] Streaming works: test with `curl --no-buffer`

### Enterprise

- [ ] LiteLLM health check passes
- [ ] API key authentication works
- [ ] Rate limiting triggers at configured limit
- [ ] LLM Guard scans input (test with PII-containing text)
- [ ] NeMo Guardrails blocks off-topic requests

### Monitoring

- [ ] GPU utilization visible in Grafana
- [ ] vLLM metrics (TTFT, throughput) visible
- [ ] Alerts configured and firing correctly (test with a known trigger)

## Phase 7: Production Hardening

### Security

1. **Change default passwords**: Update `LITELLM_MASTER_KEY`, `GRAFANA_ADMIN_PASSWORD`, PostgreSQL password
2. **Network policies**: Apply NetworkPolicies to restrict inter-namespace traffic
3. **TLS**: Enable TLS on all external-facing services
4. **RBAC**: Create LiteLLM teams with appropriate model access
5. **Secrets management**: Use Kubernetes Secrets or external secret store (Vault, GCP Secret Manager)

### Reliability

1. **Resource limits**: Ensure all pods have CPU/memory limits set
2. **Health checks**: Verify liveness and readiness probes are configured
3. **PodDisruptionBudgets**: Create PDBs for critical services
4. **Backup**: Backup PostgreSQL and Redis data
5. **Monitoring alerts**: Verify all critical alerts are configured

### Performance

1. **Run benchmarks**: `make bench-all` to establish baseline
2. **Tune vLLM**: Adjust `--max-model-len`, `--gpu-memory-utilization`, `--max-num-seqs`
3. **Enable prefix caching**: Verify `--enable-prefix-caching` is active
4. **KV-cache monitoring**: Watch for preemption events in vLLM logs

## Quick Reference: Common Operations

```bash
# Check overall status
make status-all

# View GPU status
make status-gpu

# View inference pods
make status-inference

# Tail vLLM logs
make logs-vllm

# Tail LiteLLM logs
make logs-litellm

# Run benchmarks
make bench-all

# Clean up and redeploy
make clean-inference
make deploy-70b-tp4
```
