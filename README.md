# Enterprise LLM Inference Platform on Kubernetes

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.28+-blue.svg)](https://kubernetes.io/)
[![vLLM](https://img.shields.io/badge/vLLM-v0.8.5-green.svg)](https://github.com/vllm-project/vllm)

Production-grade infrastructure for deploying large language models on Kubernetes with GPU optimization, enterprise guardrails, and comprehensive observability.

## Architecture

```
+===========================================================================+
|  LAYER 5: TESTING         vLLM Bench | Locust | k6 | Ops:Byte Calculator |
+===========================================================================+
|  LAYER 4: ENTERPRISE      LiteLLM Gateway | NeMo Guardrails | LLM Guard  |
+===========================================================================+
|  LAYER 3b: SERVING        llm-d (KV-aware routing) | Dynamo (disagg P/D)  |
|  LAYER 3a: ENGINES        vLLM: 6 profiles (MIG, TP, FP8, EAGLE3, P/D)   |
+===========================================================================+
|  LAYER 2: PLATFORM        GPU Operator/MIG | KAI Scheduler (Run:ai core) |
|                           KEDA on vLLM metrics | DCGM + Prometheus       |
+===========================================================================+
|  LAYER 1: INFRASTRUCTURE  Terraform (GKE) | k3s/kubeadm Bootstrap        |
+===========================================================================+
```

## Quick Start

```bash
# 1. Clone and configure
git clone https://github.com/richajoy/llm-inference-platform.git
cd llm-inference-platform
cp .env.example .env    # Fill in API keys

# 2. Bootstrap a single GPU node (run on the host) or provision GKE
make setup-k3s          # or: make setup-gke

# 3. Install platform (GPU Operator, Monitoring, Gateway)
make install-platform

# 4. Download models
make download-models

# 5. Deploy inference + enterprise services
make deploy-70b-fp8
make deploy-enterprise
```

## Features

- **5 Inference Profiles**: MIG slicing, tensor parallelism, FP8 quantization, EAGLE3 speculative decoding, disaggregated prefill/decode
- **Enterprise Gateway**: LiteLLM proxy with API key auth, RBAC, rate limiting, and cost tracking
- **Layered Safety**: LLM Guard (fast input scanning) + NeMo Guardrails (deep conversational safety)
- **Serving control plane**: llm-d InferencePool with KV-cache-aware endpoint picking, NVIDIA Dynamo for disaggregated prefill/decode over NIXL
- **Multi-tenant GPU scheduling**: KAI Scheduler (open-source core of NVIDIA Run:ai) with hierarchical queues, GPU quotas, fractional GPUs, priority preemption and gang scheduling
- **Event-driven autoscaling**: KEDA ScaledObjects on vLLM's own metrics (queue depth, KV-cache usage, preemption rate, TTFT/ITL p99), scale-to-zero
- **Full Observability**: DCGM (per GPU and per MIG slice, profiling counters) + vLLM + scheduler metrics in Prometheus, Grafana dashboards, 25 alert rules
- **Infrastructure as Code**: Terraform for GKE (production) plus k3s/kubeadm bootstrap for any single GPU node (dev)
- **Benchmark Suite**: vLLM bench, Locust load testing, k6 CI/CD gates, ops:byte analysis tools

## Deployment Profiles

| Profile | Model | GPUs | Technique | Latency | Cost |
|---------|-------|------|-----------|---------|------|
| A | Llama 3.1 8B | 1 MIG | FP8 + MIG 1g.10gb | Low | Lowest |
| B | Llama 3.3 70B | 4 | TP=4, FP16 | Medium | Medium |
| C | Llama 3.3 70B | 2 | TP=2, FP8 | Medium | Low |
| D | Llama 3.3 70B | 4 | TP=4 + EAGLE3 | Lowest | Medium |
| E | Llama 3.3 70B | 4+4 | Disaggregated P/D | Low (at scale) | Higher |
| F | Llama 3.1 405B | 16 | TP=8, PP=2, multi-node | High | Highest |

## Repository Structure

```
llm-inference-platform/
├── infra/              # Layer 1: Terraform (GKE), k3s/kubeadm bootstrap, Karpenter
├── platform/           # Layer 2: GPU Operator, KAI Scheduler, KEDA, Monitoring, Gateway API
├── inference/          # Layer 3: vLLM profiles (engines), llm-d and Dynamo (serving)
├── enterprise/         # Layer 4: LiteLLM, NeMo Guardrails, LLM Guard
├── benchmarks/         # Layer 5: vLLM bench, Locust, k6, analysis tools
├── docs/               # Architecture docs, runbooks, guides
└── Makefile            # Top-level orchestration (make help)
```

## Documentation

| Document | Description |
|----------|-------------|
| [Reference Architecture](docs/reference-architecture.md) | The stack, request path, the three control loops (route / scale / place), tenancy model, failure domains |
| [Architecture](docs/architecture.md) | Component-level architecture with data flow diagrams |
| [Observability](docs/observability.md) | DCGM, vLLM and scheduler metric catalogue and which loop consumes each series |
| [Ops:Byte Analysis](docs/ops-byte-analysis.md) | Theoretical foundation: arithmetic intensity for LLM inference |
| [GPU Roofline Model](docs/gpu-roofline-model.md) | Roofline analysis per GPU (A100, H100, H200, B200) |
| [MIG Sizing Guide](docs/mig-sizing-guide.md) | MIG profile selection for model/workload combinations |
| [Multi-tenant scheduling](platform/scheduler/README.md) | KAI Scheduler queues, quotas, fractional GPUs, preemption; mapping to NVIDIA Run:ai |
| [Speculative Decoding](docs/speculative-decoding-guide.md) | EAGLE3 and classic speculative decoding configuration |
| [Deployment Runbook](docs/deployment-runbook.md) | Step-by-step from zero to production |
| [Troubleshooting](docs/troubleshooting.md) | Common issues and fixes |
| [Cost Analysis](docs/cost-analysis.md) | GKE vs AWS pricing, cost per 1M tokens, optimization levers |

## Key Make Targets

```bash
make help                  # Show all available targets

# Infrastructure
make setup-k3s             # Single-node k3s on a GPU host
make setup-gke             # Provision GKE with H100 node pool

# Platform
make install-platform      # GPU Operator + Monitoring + Gateway
make install-scheduler     # KAI Scheduler: queues, fractional GPU, preemption
make install-keda          # KEDA, then install-keda-objects for the vLLM ScaledObjects

# Inference
make deploy-8b-mig         # Llama 8B on MIG slices
make deploy-70b-tp4        # Llama 70B TP=4 (FP16)
make deploy-70b-fp8        # Llama 70B FP8 TP=2
make deploy-70b-eagle3     # Llama 70B + EAGLE3 speculative
make deploy-70b-disagg     # Llama 70B disaggregated P/D

# Enterprise
make deploy-enterprise     # LiteLLM + Guardrails

# Benchmarks
make bench-all             # Full benchmark suite

# Operations
make status-all            # System health check
make logs-vllm             # Tail vLLM logs
```

## Performance Results

| Profile | TTFT (P50) | TTFT (P99) | ITL (P50) | Throughput (tok/s) |
|---------|-----------|-----------|----------|-------------------|
| A (8B MIG) | TBD | TBD | TBD | TBD |
| B (70B TP4) | TBD | TBD | TBD | TBD |
| C (70B FP8) | TBD | TBD | TBD | TBD |
| D (70B EAGLE3) | TBD | TBD | TBD | TBD |
| E (70B Disagg) | TBD | TBD | TBD | TBD |

Results will be populated after running `make bench-all` on the target hardware.

## Technology Stack

| Component | Technology | Purpose |
|-----------|-----------|---------|
| Inference Engine | vLLM v0.8.5 | OpenAI-compatible LLM serving |
| K8s Orchestration | llm-d | CRD-based model management + KV-cache routing |
| API Gateway | LiteLLM Proxy | Auth, RBAC, rate limiting, cost tracking |
| Safety (Fast) | LLM Guard | Input/output text scanning (<50ms) |
| Safety (Deep) | NeMo Guardrails | Conversational safety, topic control |
| Monitoring | Prometheus + Grafana + DCGM | GPU and inference metrics |
| IaC | Terraform | GKE provisioning, shared k8s-base module |
| Speculative Decoding | EAGLE3 | 2-4x decode latency improvement |

## Prerequisites

- A GPU host with NVIDIA drivers, or a GCP project with GPU quota
- HuggingFace token with access to Llama models
- Terraform >= 1.5.0, kubectl >= 1.28, Helm >= 3.12

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -m 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Open a Pull Request

Please ensure:
- Kubernetes manifests pass `kubectl apply --dry-run=client`
- Shell scripts pass `bash -n` syntax check
- Terraform configs pass `terraform validate`
- Documentation is updated for any new features

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.
