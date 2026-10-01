# Multi-tenant GPU scheduling: KAI Scheduler (Run:ai core)

The stock Kubernetes scheduler treats `nvidia.com/gpu` as an integer and has no
notion of who owns the GPUs. For a shared inference cluster that is not enough:
production serving needs guaranteed capacity, dev tenants need to run several
small models on one device, and batch evaluation should soak up idle GPUs
without ever blocking production.

[NVIDIA KAI Scheduler](https://github.com/NVIDIA/KAI-Scheduler) (Apache-2.0)
is the open-sourced scheduling core of NVIDIA Run:ai and adds exactly those
primitives:

| Need | KAI primitive | File |
|------|---------------|------|
| Per-tenant guaranteed / burstable GPU capacity | `Queue` with `quota`, `overQuotaWeight`, `limit`, hierarchical via `parentQueue` | `queues.yaml` |
| Several models on one GPU without MIG | pod annotation `gpu-fraction: "0.5"` or `gpu-memory: "<MiB>"` | `vllm-fractional-gpu.yaml` |
| Production never starved by batch | priority classes `train` (50) < `build-preemptible` (75) < `build` (100) < `inference` (125); classes >= 100 are non-preemptible and confined to quota | `batch-eval-preemptible.yaml` |
| All-or-nothing placement for TP / prefill+decode pairs | `PodGroup` with `minMember` (gang scheduling) | `vllm-tp-gang.yaml` |

## Install

```bash
# after platform/gpu-operator
bash platform/scheduler/install.sh                      # NonMemoryEnforced (default)
bash platform/scheduler/install.sh --gpu-sharing-mode HamiCore     # + CUDA memory isolation
bash platform/scheduler/install.sh --gpu-sharing-mode NvFractions  # NVIDIA gpu-fractioning (CDI/NRI)
```

Then opt a workload in with two fields on the pod template:

```yaml
metadata:
  labels:
    kai.scheduler/queue: inference-dev
spec:
  schedulerName: kai-scheduler
```

Everything else in `inference/` keeps using the default scheduler unless you add
those two lines, so adoption is per-deployment.

## Queue layout in `queues.yaml`

```
gpu-cluster (8 GPUs)
├── inference-prod   quota 5, limit 8, priority 200, weight 3   (production serving)
├── inference-dev    quota 2, limit 4, priority 100, weight 1   (fractional dev replicas)
└── batch            quota 1, limit -1, priority 50,  weight 1  (preemptible eval / fine-tune)
```

How it plays out on one node:

1. Idle cluster, `batch` submits a 4-GPU eval job: it gets all 4 (1 in quota, 3 over quota).
2. `inference-prod` scales from 3 to 5 replicas: the scheduler reclaims the 3 over-quota GPUs from `batch` by preempting the `train`-priority job. The Job controller re-creates the pod; it waits in queue.
3. `inference-dev` deploys two `gpu-fraction: "0.5"` Llama-8B replicas: both land on one GPU, consuming 1.0 of its 2-GPU quota.
4. Non-preemptible classes (`inference`, `build`) can never exceed their queue's quota, so a misconfigured production rollout cannot eat the dev tenant's guarantee.

## Fractional GPU vs MIG

| | MIG (`platform/gpu-operator`, `inference/vllm/profiles/*mig*`) | Fractional GPU (this directory) |
|---|---|---|
| Isolation | Hardware: dedicated SMs, HBM slice, L2 | Software: shared SMs; memory capped only in HamiCore / NvFractions modes |
| Granularity | Fixed profiles (1g.10gb, 2g.20gb, 3g.40gb, 7g.80gb) | Any ratio, or an exact MiB amount |
| Reconfiguration | GPU reset, node drain | Scheduling-time only |
| Performance interference | None | Yes: two vLLM replicas contend for HBM bandwidth |
| Best for | Latency-SLA tenants, noisy neighbours | Dev, low-QPS models, bursty internal tools |

For vLLM specifically, set `--gpu-memory-utilization` below the requested
fraction (0.45 for a 0.5 share); vLLM otherwise measures free HBM at startup
and allocates the whole device to its KV cache.

## Mapping to NVIDIA Run:ai

If you run the commercial platform, the same concepts exist under different
names; the manifests here translate directly.

| KAI (this repo) | Run:ai |
|-----------------|--------|
| `Queue` (`scheduling.run.ai/v2`) | Project (UI/API), backed by the same Queue CRD; Departments = parent queues |
| `quota` / `overQuotaWeight` / `limit` | Project "GPU quota", "over-quota weight", "limit" |
| label `kai.scheduler/queue` | label `runai/queue` (auto-set when submitting via `runai submit` / Workloads UI) |
| `schedulerName: kai-scheduler` | `schedulerName: runai-scheduler` |
| annotation `gpu-fraction` / `gpu-memory` | same annotations; `runai submit --gpu 0.5` / `--gpu-memory 20G` |
| priority classes `train` / `build` / `inference` | workload types Training / Workspace / Inference |
| `PodGroup` | created automatically for Distributed Training and Inference workloads |
| Node pools (`kai.scheduler/nodepool` label) | Node Pools with per-pool quotas |

Run:ai adds what KAI deliberately leaves out: a control plane with RBAC,
per-project dashboards, GPU time-slicing policies, an `InferenceWorkload`
CRD with built-in autoscaling, and audit. The scheduling decisions are the
same engine.

## Observability

`servicemonitors.yaml` (applied by `install.sh` when the Prometheus Operator is
present) scrapes the scheduler, queue controller and binder. Queue
allocated-vs-requested GPUs and pending pods per queue sit next to DCGM and
vLLM metrics in Grafana; `docs/reference-architecture.md` shows where queue
saturation feeds the capacity-planning loop.
