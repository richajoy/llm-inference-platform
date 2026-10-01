# Reference Architecture

One cluster, three tenants, two serving modes. This page is the map; every box
is a directory in this repo.

## The stack

```
                         clients (OpenAI-compatible API)
                                    |
 +==================================v=========================================+
 |  EDGE            Gateway API (GKE L7 / Envoy)  ->  LiteLLM proxy           |
 |  enterprise/     authn, API keys, per-tenant rate limits, model routing,   |
 |                  NeMo Guardrails + LLM Guard on request and response       |
 +==================================|=========================================+
                                    |
 +==================================v=========================================+
 |  SERVING CONTROL PLANE  (choose per model)                                 |
 |  inference/llm-d/      llm-d InferencePool + EPP: KV-cache-aware and      |
 |                        prefix-aware endpoint picking across vLLM replicas  |
 |  inference/dynamo/     Dynamo Smart Router: prefill / decode worker pools, |
 |                        KV transfer over NIXL, request-level scheduling     |
 +==================================|=========================================+
                                    |
 +==================================v=========================================+
 |  ENGINES         vLLM (inference/vllm/profiles)                            |
 |                  A 8B-FP8 on MIG 1g.10gb   B 70B TP=4   C 70B-FP8 TP=2     |
 |                  D 70B + EAGLE3 spec-decode   E 70B disaggregated P/D      |
 |                  F 405B multi-node (LeaderWorkerSet / KubeRay)             |
 +==================================|=========================================+
                                    |
 +==================================v=========================================+
 |  PLATFORM        GPU Operator (drivers, MIG, DCGM)   Network Operator (IB) |
 |  platform/       KAI Scheduler: queues, quotas, fractional GPU, gang       |
 |                  KEDA: replicas driven by vLLM metrics                     |
 |                  kube-prometheus-stack: DCGM + vLLM + scheduler metrics    |
 +==================================|=========================================+
                                    |
 +==================================v=========================================+
 |  INFRASTRUCTURE  GKE a3 node pools (Terraform, Karpenter)                  |
 |  infra/          or a single 8xH100 host with k3s / kubeadm                |
 +============================================================================+
```

## Request path

```
client --> Gateway API --> LiteLLM --> [guardrails] --> llm-d EPP --> vLLM pod
             (TLS,           (key,       (NeMo/LLM       (score each       (schedule,
             routing)        quota,       Guard)          endpoint:         prefill,
                             model                        KV-cache hit,     decode)
                             alias)                       queue depth,
                                                          load)
                                                      --> Dynamo router --> prefill pool --NIXL--> decode pool
```

1. **Gateway API** terminates TLS and routes `/v1/*` to LiteLLM.
2. **LiteLLM** authenticates the API key, applies the tenant's TPM/RPM limits,
   maps the public model alias to a backend, and calls the guardrail hooks.
3. **llm-d** (default): the Endpoint Picker scores every ready vLLM replica
   with the weights in `inference/llm-d/inference-pool/epp-config.yaml`:
   `PrefixCacheScorer` 0.7 (route to the replica already holding the prompt's
   KV blocks), `LeastLoadScorer` 0.2, `LeastQueueScorer` 0.1, refreshed from
   each replica's `/metrics` every 50 ms. The highest score gets the request.
4. **Dynamo** (profile E): the Smart Router splits each request into a prefill
   job on the prefill pool and a decode job on the decode pool; KV blocks move
   between them over NIXL. Prefill is compute-bound and decode is
   HBM-bandwidth-bound (see `docs/gpu-roofline-model.md`), so sizing the two
   pools independently is what makes this profile pay off.
5. **vLLM** runs continuous batching with paged KV cache. Every pod exports
   `/metrics`; those series drive everything in the next two sections.

## Control loops

Three loops act on the same metrics at different time scales.

| Loop | Signal | Actor | Horizon | Config |
|------|--------|-------|---------|--------|
| Route | per-replica KV-cache usage, queue depth, prefix hit | llm-d EPP / Dynamo router | per request | `inference/llm-d/inference-pool/epp-config.yaml` |
| Scale | `vllm:num_requests_waiting`, `kv_cache_usage_perc`, TTFT/ITL p99, preemption rate | KEDA ScaledObject | 30 s to minutes | `platform/autoscaling/keda-vllm.yaml`, `keda-profiles/` |
| Place | queue quota, priority, `gpu-fraction` | KAI Scheduler | per pod | `platform/scheduler/queues.yaml` |

How they compose: KEDA decides *how many* replicas a model deserves from the
model's own back-pressure; KAI decides *whether and where* those replicas may
run given the tenant's quota; the router decides *which* replica each request
goes to. A KEDA scale-up that exceeds the tenant's queue quota simply waits in
the queue (visible as pending pods on the scheduler dashboard) rather than
evicting another tenant, unless the pending pods carry a non-preemptible
priority and are within quota, in which case `batch` work is reclaimed.

## Tenancy model

```
gpu-cluster (8xH100)
├── inference-prod   5 GPUs guaranteed, burst to 8, priority 200   profiles B/C/D/E
├── inference-dev    2 GPUs guaranteed, burst to 4, priority 100   fractional 8B replicas, canaries
└── batch            1 GPU  guaranteed, unlimited burst, priority 50, preemptible (lm-eval, fine-tunes)
```

Isolation options, strongest first:

1. **Dedicated node pool** (`infra/karpenter/gpu-nodeclass.yaml` + KAI node
   pool label): separate hardware per tenant.
2. **MIG** (`platform/gpu-operator/values-mig-*.yaml`): hardware-partitioned
   slices on shared GPUs; fixed sizes.
3. **Fractional GPU** (`platform/scheduler/vllm-fractional-gpu.yaml`): software
   partitioning at any ratio; memory enforcement only in HamiCore/NvFractions
   modes.
4. **Queue quota only**: whole GPUs, shared node, no runtime isolation.

LiteLLM keys map 1:1 to queues so that a tenant's API quota and its GPU quota
are the same tenant.

## Observability plane

```
 DCGM exporter (per GPU / MIG slice)  --+
 vLLM /metrics (per replica)           --+--> Prometheus --> Grafana dashboards
 KAI scheduler + queue controller      --+         |            platform/monitoring/dashboards/
 LiteLLM, Gateway, KEDA                --+         +--> Alertmanager (gpu-alerts, inference-alerts)
                                                   +--> KEDA (scale triggers)
```

The metric catalogue and which loop consumes each series is in
`docs/observability.md`.

## Deployment profiles and where they land

| Profile | Engine layout | Serving control plane | Queue | Scale signal that matters most |
|---------|---------------|-----------------------|-------|-------------------------------|
| A: 8B FP8 on MIG | 1g.10gb slice per replica | llm-d pool | inference-dev / prod | `num_requests_waiting` |
| B: 70B TP=4 | 4 GPUs, 1 pod | llm-d pool | inference-prod | TTFT p99 |
| C: 70B FP8 TP=2 | 2 GPUs, 1 pod | llm-d pool | inference-prod | `kv_cache_usage_perc` |
| D: 70B + EAGLE3 | 4 GPUs, spec decode | llm-d pool | inference-prod | ITL p99 |
| E: 70B disaggregated | 4 prefill + 4 decode | Dynamo | inference-prod (gang) | prefill queue vs decode KV usage |
| F: 405B multi-node | 2 nodes x 8 GPUs, PP=2 | llm-d pool | inference-prod (gang) | TTFT p99 |

## Failure domains

| Failure | Blast radius | Mitigation in this repo |
|---------|--------------|-------------------------|
| GPU XID / DBE ECC | one replica | `gpu-alerts.yaml` pages; KAI reschedules the pod to another GPU; EPP stops routing to the unready endpoint |
| KV-cache exhaustion | one replica (preemptions, latency) | KEDA preemption-rate and KV-usage triggers add a replica; `inference-alerts.yaml` warns at 85% |
| Prefill pool saturated (profile E) | TTFT for all requests on that model | Scale prefill workers independently (`keda-profiles/llama-70b-disagg-pd.yaml`) |
| Batch tenant floods the cluster | none for inference-prod | `train` priority is preemptible; prod quota is reclaimed |
| Node loss | all replicas on it | Multi-zone GKE node pools; LeaderWorkerSet restarts the 405B group |
| Gateway / LiteLLM down | everything | Stateless, HPA on CPU; the only hard dependency is its Postgres (keys) |

## What this is not

Single-region, single-cluster. Multi-cluster routing, model registries, and a
KV-cache tiering service (CPU/NVMe offload across nodes) are out of scope;
llm-d's and Dynamo's own roadmaps cover the last one.
