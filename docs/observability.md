# Observability

Three metric sources, one Prometheus, four consumers. The point of this page is
the last column: every series listed here is read by something that acts on it.

```
DCGM exporter --------+
vLLM /metrics --------+--> Prometheus --> Grafana (platform/monitoring/dashboards)
KAI scheduler --------+        |      --> Alertmanager (platform/monitoring/alerts)
LiteLLM / Gateway ----+        +------> KEDA ScaledObjects (platform/autoscaling)
                               +------> llm-d EPP (scrapes vLLM directly, 50 ms)
```

Install: `make install-monitoring` (kube-prometheus-stack, DCGM exporter if the
GPU Operator did not already deploy it, dashboards, alert rules).

## GPU: DCGM

Exported per GPU, and per MIG instance when MIG is on
(`DCGM_EXPORTER_KUBERNETES_GPU_ID_TYPE=uid` adds `GPU_I_ID` / `GPU_I_PROFILE`
labels). The field list is `platform/monitoring/dcgm-exporter/dcgm-metrics-configmap.yaml`;
it is complete, not additive.

| Series | Meaning | Consumer |
|--------|---------|----------|
| `DCGM_FI_DEV_GPU_UTIL` | coarse "GPU busy" | `gpu-overview.json`, `GPUUnderutilized` alert |
| `DCGM_FI_PROF_SM_ACTIVE` | fraction of cycles with a warp resident | efficiency alert, dashboard |
| `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE` | tensor-core pipe active | `GPUTensorPipeIdleUnderLoad` (decode is HBM-bound when SM is busy and this is low) |
| `DCGM_FI_PROF_DRAM_ACTIVE` | HBM interface busy | same alert; the roofline's memory axis |
| `DCGM_FI_DEV_FB_USED` / `FB_TOTAL` | HBM used | `GPUMemoryHigh`/`Exhausted`; MIG sizing |
| `DCGM_FI_DEV_GPU_TEMP`, `POWER_USAGE`, `CLOCK_THROTTLE_REASONS` | thermal/power | temperature and throttling alerts |
| `DCGM_FI_DEV_XID_ERRORS` | last XID code | `GPUXidErrors` (page) |
| `DCGM_FI_DEV_ECC_DBE_VOL_TOTAL`, `ROW_REMAP_FAILURE` | memory integrity | `GPUDoubleBitECCError`, `GPURowRemapFailure` (page, drain node) |
| `DCGM_FI_PROF_NVLINK_TX/RX_BYTES`, `NVLINK_BANDWIDTH_TOTAL` | TP all-reduce traffic | `NVLinkBandwidthLow` for TP>1 profiles |

Reading SM vs tensor-pipe together is what connects this page to
`docs/gpu-roofline-model.md`: decode at small batch shows SM_ACTIVE high,
PIPE_TENSOR_ACTIVE low, DRAM_ACTIVE high (memory-bound, left of the ridge
point); prefill shows all three high (compute-bound).

## Engine: vLLM

Every vLLM pod exports `/metrics` on its HTTP port; the ServiceMonitor in
`platform/monitoring/kube-prometheus-stack` scrapes the `inference` namespace.
Names below are the vLLM >= 0.10 names; the older `vllm:gpu_cache_usage_perc`
and `vllm:time_per_output_token_seconds` are queried with `or` where the
platform still supports v0.8.x images.

| Series | Meaning | Consumer |
|--------|---------|----------|
| `vllm:num_requests_waiting` | requests admitted but not yet scheduled (scheduler `waiting` queue) | KEDA trigger 4 (most responsive to bursts), EPP `LeastQueueScorer`, `inference-sla.json` |
| `vllm:num_requests_running` | requests in the current batch | KEDA trigger 6 (approaching `--max-num-seqs`), EPP `LeastLoadScorer` |
| `vllm:kv_cache_usage_perc` | fraction of KV blocks allocated | KEDA trigger 5 (scale at 85%), alerts at 85/95%, EPP |
| `vllm:num_preemptions_total` | recompute preemptions (a running request lost its blocks) | KEDA trigger 7, `PreemptionRateHigh`/`PreemptionRateWarning` alerts |
| `vllm:prefix_cache_hits` / `prefix_cache_queries` | prefix-cache effectiveness | dashboard; validates `PrefixCacheScorer` weight |
| `vllm:time_to_first_token_seconds` (histogram) | prefill latency | KEDA trigger 1 (p99 > 3 s), SLO dashboard |
| `vllm:inter_token_latency_seconds` (histogram) | decode latency per token | KEDA trigger 2 (p99 > 100 ms) |
| `vllm:e2e_request_latency_seconds` (histogram) | whole request | KEDA trigger 3, SLO alerts |
| `vllm:request_queue_time_seconds` | time spent in `waiting` | dashboard; separates "slow model" from "not enough replicas" |
| `vllm:generation_tokens_total`, `prompt_tokens_total` | throughput | cost-per-token dashboard (`docs/cost-analysis.md`) |
| `vllm:request_success_total{finished_reason}` | stop vs length vs abort | error-rate alerts |

KEDA's trigger set in `platform/autoscaling/keda-vllm.yaml` is deliberately
ordered: queue depth and KV usage are leading indicators (they move before
latency does); TTFT/ITL p99 are the SLO backstop; preemption rate catches the
case where latency looks fine but every request is being recomputed.

## Scheduler: KAI

`platform/scheduler/servicemonitors.yaml` scrapes the scheduler, queue
controller and binder.

| Series (prefix `kai_`) | Meaning | Consumer |
|--------|---------|----------|
| queue allocated vs requested GPUs | per-queue quota pressure | capacity planning: sustained requested > allocated on `inference-prod` means buy GPUs, on `batch` means expected |
| pending pods per queue | workloads waiting for quota | explains a KEDA scale-up that never materialised |
| preemptions | reclaim events | correlate with `batch` job restarts |

## Gateway: LiteLLM

LiteLLM exports per-key and per-model request counts, token usage and
latency on `/metrics`; `litellm-gateway.json` shows spend per tenant. Because
keys map to KAI queues, tenant spend and tenant GPU quota line up on one row.

## Dashboards

| File | Shows |
|------|-------|
| `gpu-overview.json` | per-GPU/MIG utilisation, memory, temperature, XID timeline |
| `vllm-metrics.json` | queue depth, batch size, KV usage, preemptions, cache hit rate per model |
| `inference-sla.json` | TTFT / ITL / E2E percentiles against SLO lines |
| `litellm-gateway.json` | requests, tokens and spend per API key |

## Alerts

`platform/monitoring/alerts/gpu-alerts.yaml` (13 rules: thermal, power, XID,
ECC, row remap, NVLink, efficiency, exporter missing) and
`inference-alerts.yaml` (12 rules: TTFT SLO, KV usage, preemption rate, queue
depth, error rate, pod readiness, LiteLLM errors and rate-limit rejections). Severity `critical` pages; `warning` goes to the
on-call channel; `info` is dashboard-only.
