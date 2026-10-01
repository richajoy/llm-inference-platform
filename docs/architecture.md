# System Architecture

## Overview

The Enterprise LLM Inference Platform is a production-grade Kubernetes-based system for deploying, serving, and managing large language models at scale. It is organized into five distinct layers, each with clear responsibilities and well-defined interfaces.

## 5-Layer Architecture

```
+===========================================================================+
|                          LAYER 5: TESTING & BENCHMARKS                    |
|  benchmarks/                                                              |
|  +----------------+  +--------------+  +------------+  +---------------+  |
|  | vLLM Bench     |  | Locust       |  | k6 CI/CD   |  | Ops:Byte     |  |
|  | (latency/tput) |  | (load test)  |  | (SLA gate) |  | Calculator   |  |
|  +----------------+  +--------------+  +------------+  +---------------+  |
+===========================================================================+
           |                    |                |                |
+===========================================================================+
|                       LAYER 4: ENTERPRISE SERVICES                        |
|  enterprise/                                                              |
|  +-------------------+  +------------------+  +---------------------+     |
|  | LiteLLM Proxy     |  | NeMo Guardrails  |  | LLM Guard           |    |
|  | - Auth & RBAC     |  | - Topic control  |  | - Input scanning    |    |
|  | - Rate limiting   |  | - Jailbreak det. |  | - Output scanning   |    |
|  | - Cost tracking   |  | - Conv. safety   |  | - PII detection     |    |
|  | - Model routing   |  | (deep, post-LLM) |  | (fast, pre-LLM)    |    |
|  +-------------------+  +------------------+  +---------------------+     |
+===========================================================================+
           |                    |                |
+===========================================================================+
|                        LAYER 3: INFERENCE ENGINE                          |
|  inference/                                                               |
|  +-------------------------------+  +----------------------------------+  |
|  | vLLM v0.8.x                   |  | llm-d Orchestration              |  |
|  | - 5 deployment profiles       |  | - InferencePool CRD             |  |
|  | - Tensor parallelism (TP)     |  | - InferenceModel CRD            |  |
|  | - MIG slicing                 |  | - KV-cache aware routing (EPP)  |  |
|  | - FP8 quantization            |  | - Variant autoscaling           |  |
|  | - EAGLE3 speculative decode   |  | - Gateway API integration       |  |
|  | - Disaggregated prefill/decode|  +----------------------------------+  |
|  | - Prefix caching              |  | Dynamo (optional)                |  |
|  | - Chunked prefill             |  | - Smart Router                  |  |
|  +-------------------------------+  | - Disaggregated P/D at scale    |  |
|                                     +----------------------------------+  |
+===========================================================================+
           |                    |
+===========================================================================+
|                      LAYER 2: KUBERNETES PLATFORM                         |
|  platform/                                                                |
|  +------------------+  +-----------------+  +------------------+          |
|  | GPU Operator     |  | Monitoring      |  | Gateway API      |          |
|  | - NVIDIA drivers |  | - Prometheus    |  | - GatewayClass   |          |
|  | - Container tkit |  | - Grafana       |  | - Envoy Gateway  |          |
|  | - DCGM exporter  |  | - DCGM metrics  |  | - HTTPRoutes     |          |
|  | - MIG manager    |  | - Custom alerts |  | - Inference Ext. |          |
|  +------------------+  +-----------------+  +------------------+          |
|  +------------------+  +-----------------+                                |
|  | Network Operator |  | Autoscaling     |                                |
|  | - InfiniBand     |  | - HPA           |                                |
|  | - SR-IOV         |  | - KEDA          |                                |
|  | - GPUDirect RDMA |  | - Prom Adapter  |                                |
|  +------------------+  +-----------------+                                |
+===========================================================================+
           |
+===========================================================================+
|                      LAYER 1: INFRASTRUCTURE                              |
|  infra/                                                                   |
|  +---------------------+  +---------------------+  +------------------+  |
|  | RunPod Terraform     |  | GKE Terraform       |  | K8s Bootstrap    |  |
|  | - 8xH100 SXM pod    |  | - A3 Ultra nodepool  |  | - k3s install    |  |
|  | - 500Gi storage      |  | - InfiniBand network |  | - kubeadm setup  |  |
|  | - GPU selection      |  | - Multi-zone HA      |  | - Helm + repos   |  |
|  +---------------------+  +---------------------+  +------------------+  |
+===========================================================================+
```

## Data Flow

### Request Processing Pipeline

```
                                 +---------+
                                 | Client  |
                                 | (API)   |
                                 +----+----+
                                      |
                                      | OpenAI-compatible API
                                      v
                            +-------------------+
                            |   LiteLLM Proxy   |
                            |   (port 4000)     |
                            | - Authenticate    |
                            | - Check rate limit|
                            | - Route to model  |
                            +--------+----------+
                                     |
                      +--------------+--------------+
                      |                             |
                      v                             v
              +---------------+            +---------------+
              |  LLM Guard    |            | (bypass for   |
              |  (port 8060)  |            |  trusted)     |
              | - Scan input  |            +-------+-------+
              | - PII detect  |                    |
              | - Toxicity    |                    |
              +-------+-------+                    |
                      |                            |
                      | Pass / Reject              |
                      v                            |
              +------------------+                 |
              | NeMo Guardrails  |                 |
              | (port 8090)      |<----------------+
              | - Topic guard    |
              | - Jailbreak det. |
              | - Flow control   |
              +--------+---------+
                       |
                       v
              +------------------+
              |  Gateway API     |
              |  (Envoy)        |
              |  + llm-d EPP    |
              | - KV-cache route|
              | - Load balance  |
              +--------+---------+
                       |
          +------------+------------+
          |            |            |
          v            v            v
   +----------+  +----------+  +----------+
   | vLLM     |  | vLLM     |  | vLLM     |
   | Pod 1    |  | Pod 2    |  | Pod N    |
   | (GPU 0-3)|  | (GPU 4-7)|  | (MIG)   |
   +----------+  +----------+  +----------+
```

### Disaggregated Prefill/Decode Flow

```
   Request arrives
        |
        v
   +----------+       +----------------+       +---------------+
   | Proxy    | ----> | Prefill Pod    | ----> | KV-Cache      |
   | (Router) |       | (kv_producer)  |       | Transfer      |
   +----------+       | TP=4, GPU 0-3  |       | (LMCache/     |
        ^             +----------------+       |  connector)   |
        |                                      +-------+-------+
        |                                              |
        |             +----------------+               |
        +------------ | Decode Pod     | <-------------+
                      | (kv_consumer)  |
                      | TP=4, GPU 4-7  |
                      +----------------+
```

## Technology Stack

| Layer | Component | Technology | Version | Purpose |
|-------|-----------|-----------|---------|---------|
| 1 | IaC | Terraform | >= 1.5 | Multi-cloud provisioning |
| 1 | K8s (dev) | k3s | latest | Lightweight K8s on RunPod |
| 1 | K8s (prod) | GKE | 1.29+ | Managed K8s with GPU support |
| 2 | GPU Management | NVIDIA GPU Operator | v24.9 | Driver, toolkit, DCGM, MIG |
| 2 | Networking | NVIDIA Network Operator | v24.7 | InfiniBand, SR-IOV, GPUDirect RDMA |
| 2 | Monitoring | Prometheus + Grafana | latest | Metrics collection and visualization |
| 2 | GPU Metrics | DCGM Exporter | latest | Per-GPU utilization, memory, temp |
| 2 | Ingress | Gateway API + Envoy | v1.2 | K8s-native routing |
| 2 | Autoscaling | HPA + KEDA | latest | Pod scaling on GPU/inference metrics |
| 3 | Inference | vLLM | v0.8.5 | OpenAI-compatible LLM serving |
| 3 | Orchestration | llm-d | latest | CRD-based model management |
| 3 | Routing | llm-d EPP | latest | KV-cache aware request routing |
| 3 | Advanced | Dynamo | latest | Datacenter-scale disaggregated P/D |
| 4 | Gateway | LiteLLM Proxy | latest | Auth, RBAC, rate limiting, cost |
| 4 | Safety (fast) | LLM Guard | latest | Input/output text scanning (<50ms) |
| 4 | Safety (deep) | NeMo Guardrails | latest | Conversational safety, topic control |
| 5 | Benchmarks | vLLM bench serve | built-in | Latency and throughput benchmarks |
| 5 | Load Testing | Locust | latest | HTTP load testing with TTFT tracking |
| 5 | CI/CD Testing | k6 | latest | SLA gate testing with thresholds |
| 5 | Analysis | Custom Python | 3.10+ | Ops:byte calculator, roofline plots |

## Namespace Mapping

| Namespace | Layer | Components |
|-----------|-------|------------|
| `gpu-operator` | 2 | NVIDIA GPU Operator, device plugin, MIG manager, DCGM |
| `network-operator` | 2 | NVIDIA Network Operator, SR-IOV, RDMA |
| `monitoring` | 2 | Prometheus, Grafana, DCGM Exporter, alerting rules |
| `gateway` | 2 | Envoy Gateway, GatewayClass, Gateway |
| `inference` | 3 | vLLM deployments, model cache PVC, llm-d CRDs |
| `enterprise` | 4 | LiteLLM, PostgreSQL, Redis, NeMo Guardrails, LLM Guard |

## Network Architecture

### Intra-Node Communication (RunPod 8xH100 SXM)

```
    +---------------------------------------------------------------+
    |                    RunPod 8xH100 SXM Pod                      |
    |                                                               |
    |   GPU 0 <--NVLink--> GPU 1 <--NVLink--> GPU 2 <--NVLink-->   |
    |     |                  |                  |                   |
    |   NVSwitch            NVSwitch            NVSwitch            |
    |     |                  |                  |                   |
    |   GPU 3 <--NVLink--> GPU 4 <--NVLink--> GPU 5 <--NVLink-->   |
    |     |                  |                  |                   |
    |   NVSwitch            NVSwitch            NVSwitch            |
    |     |                  |                  |                   |
    |   GPU 6 <--NVLink--> GPU 7                                    |
    |                                                               |
    |   NVLink Bandwidth: 900 GB/s (bi-directional, all-to-all)    |
    |   HBM3 per GPU: 80 GB @ 3,350 GB/s                           |
    +---------------------------------------------------------------+
```

Within a single node, all 8 H100 SXM GPUs are connected via NVSwitch providing full 900 GB/s bi-directional NVLink bandwidth. Tensor parallelism (TP) operations use NCCL over NVLink for all-reduce communication. This is the default for RunPod single-pod deployments.

### Inter-Node Communication (GKE Multi-Node)

```
    +---------------------------+     +---------------------------+
    |        Node 1             |     |        Node 2             |
    |  8xH100 SXM (80GB each)  |     |  8xH100 SXM (80GB each)  |
    |                           |     |                           |
    |  GPU 0..7 (NVLink mesh)   |     |  GPU 0..7 (NVLink mesh)  |
    |           |                |     |           |               |
    |     +-----+-----+         |     |     +-----+-----+        |
    |     |  ConnectX-7|  <---- InfiniBand ---->  |ConnectX-7|   |
    |     | 400 Gb/s   |         |     |     | 400 Gb/s  |        |
    |     +------------+         |     |     +-----------+        |
    +---------------------------+     +---------------------------+
```

For multi-node deployments (e.g., Llama 405B with PP=2), inter-node communication uses:

- **InfiniBand HDR/NDR**: 400 Gb/s per port via ConnectX-7 NICs
- **GPUDirect RDMA**: Bypasses CPU for GPU-to-GPU transfers across nodes
- **NCCL**: Handles the collective communication (all-reduce, send/recv for pipeline parallelism)
- **NVIDIA Network Operator**: Manages SR-IOV and RDMA resources in Kubernetes

### Key NCCL Environment Variables for Multi-Node

```bash
NCCL_IB_DISABLE=0              # Enable InfiniBand
NCCL_IB_HCA=mlx5               # Use Mellanox HCA
NCCL_SOCKET_IFNAME=eth0        # Fallback interface
NCCL_DEBUG=INFO                 # Logging level
NCCL_IB_GID_INDEX=3            # RoCE GID index
NCCL_NET_GDR_LEVEL=PIX         # GPUDirect RDMA level
```

## Inference Deployment Profiles

| Profile | Model | GPUs | Parallelism | Precision | Key Feature |
|---------|-------|------|-------------|-----------|-------------|
| A | Llama 3.1 8B | 1 (MIG 1g.10gb) | None | FP8 | MIG slicing, max density |
| B | Llama 3.3 70B | 4 | TP=4 | FP16 | Baseline, prefix caching |
| C | Llama 3.3 70B | 2 | TP=2 | FP8 | Half the GPUs via quantization |
| D | Llama 3.3 70B | 4 | TP=4 | FP16 | EAGLE3 speculative decoding |
| E | Llama 3.3 70B | 4+4 | TP=4 (each) | FP16 | Disaggregated prefill/decode |
| F | Llama 3.1 405B | 16 (2 nodes) | TP=8, PP=2 | FP16 | Multi-node, InfiniBand |

## Storage Architecture

```
PVC: model-cache-pvc (500Gi, ReadWriteOnce)
Mount: /models

/models/
  meta-llama/
    Llama-3.1-8B-Instruct/          # 16 GB (FP16)
    Llama-3.3-70B-Instruct/         # 141 GB (FP16)
    Llama-3.1-405B-Instruct/        # 810 GB (FP16)
  nvidia/
    Llama-3.3-70B-Instruct-FP8/     # 70 GB (FP8)
  yuhuili/
    EAGLE3-LLaMA3.3-Instruct-70B/   # Draft model for speculative decoding
```

All vLLM pods mount the same PVC at `/models`, sharing the downloaded weights. The download job pulls all models from HuggingFace using `huggingface-cli download` with the `HF_TOKEN` secret.

## Security Architecture

```
Internet --> LiteLLM (API Key auth) --> LLM Guard (scan) --> NeMo (guard) --> vLLM
                 |
                 +-- PostgreSQL (team/key store)
                 +-- Redis (rate limit state)
```

- **Authentication**: API key-based via LiteLLM. Keys are scoped to teams with budget limits.
- **Authorization**: RBAC through LiteLLM team/user model. Teams have model access controls.
- **Rate Limiting**: Redis-backed per-key rate limiting in LiteLLM.
- **Input Safety**: LLM Guard scans all inputs for PII, prompt injection, toxicity (<50ms).
- **Output Safety**: NeMo Guardrails enforces topic control, jailbreak detection on outputs.
- **Network**: All inter-service communication is cluster-internal (ClusterIP services). Only LiteLLM is exposed externally.
