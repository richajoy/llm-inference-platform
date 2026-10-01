# Guardrails Architecture

This directory contains two complementary content safety systems that form a layered defense pipeline for the LLM inference platform.

## Pipeline Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │              Request Pipeline               │
                    │                                             │
  Client ──────────┤  1. LLM Guard      2. NeMo Guardrails       │
  Request          │  (Fast scan)       (Deep analysis)           │
                    │  ~20-50ms          ~400ms-2s                │
                    │                                             │
                    │  PromptInjection   check jailbreak          │
                    │  Toxicity          check input toxicity     │
                    │  Secrets           mask pii                 │
                    │  BanTopics                                  │
                    │  InvisibleText                              │
                    └────────────────────┬────────────────────────┘
                                         │
                                         ▼
                               ┌─────────────────┐
                               │   vLLM Backend   │
                               │   (Inference)    │
                               └────────┬────────┘
                                         │
                    ┌────────────────────▼────────────────────────┐
                    │             Response Pipeline                │
                    │                                             │
                    │  3. NeMo Guardrails    4. LLM Guard         │
                    │  (Deep analysis)       (Fast scan)          │
                    │                                             │
                    │  check output toxicity  Bias                │
                    │  check factual          MaliciousURLs       │
                    │  consistency            Sensitive (PII)     │
                    │                         Toxicity            │
                    └────────────────────┬────────────────────────┘
                                         │
                                         ▼
                                    Client Response
```

## LLM Guard vs NeMo Guardrails

| Aspect | LLM Guard | NeMo Guardrails |
|--------|----------|-----------------|
| **Approach** | Small classification models | Full LLM-based evaluation |
| **Latency** | 20-50ms total | 400ms-2s total |
| **Accuracy** | Good for clear-cut cases | Better for nuanced/subtle cases |
| **GPU Required** | No (CPU only) | Yes (uses vLLM backend) |
| **Customization** | Config-based scanners | Programmable flows (Colang) |
| **PII Handling** | Entity recognition + redaction | LLM-based detection + masking |
| **Best For** | High-throughput first pass | Deep content analysis |

## When to Use Which

### LLM Guard Only (Low Latency)
- High-throughput APIs where latency is critical
- Simple use cases (PII redaction, secret detection)
- When 20-50ms overhead is the budget

### NeMo Guardrails Only (High Accuracy)
- Sensitive domains (healthcare, finance, legal)
- Complex policy enforcement
- When accuracy matters more than latency

### Both (Defense in Depth) -- Recommended
- Enterprise production deployments
- Compliance-heavy environments
- Maximum safety coverage

## Combined Deployment

### Step 1: Deploy LLM Guard (fast first pass)
```bash
kubectl apply -f enterprise/guardrails/llm-guard/config.yaml
kubectl apply -f enterprise/guardrails/llm-guard/deployment.yaml
```

### Step 2: Deploy NeMo Guardrails (deep analysis)
```bash
kubectl create configmap nemo-guardrails-config \
  --from-file=config.yml=enterprise/guardrails/nemo-guardrails/config/config.yml \
  --from-file=prompts.yml=enterprise/guardrails/nemo-guardrails/config/prompts.yml \
  -n enterprise

kubectl apply -f enterprise/guardrails/nemo-guardrails/deployment.yaml
```

### Step 3: Verify Both
```bash
kubectl -n enterprise get pods -l app.kubernetes.io/part-of=safety-layer
```

## Integration with LiteLLM

LiteLLM can be configured to call guardrails as pre/post-processing hooks. The recommended integration pattern:

```
Client → LiteLLM (auth/routing) → LLM Guard (fast) → NeMo (deep) → vLLM → NeMo → LLM Guard → Client
```

In practice, the guardrails are called as middleware in the request pipeline. LiteLLM's `guardrail` callback can be configured to call LLM Guard and NeMo Guardrails endpoints.

## Monitoring

Both systems expose metrics for Prometheus:

- **LLM Guard**: Request counts, scan latencies, scanner trigger rates
- **NeMo Guardrails**: Rail trigger counts, latencies, blocked request rates

Dashboard queries:
```promql
# Blocked request rate (LLM Guard)
rate(llm_guard_scanner_triggers_total[5m])

# Average scan latency
histogram_quantile(0.95, rate(llm_guard_scan_duration_seconds_bucket[5m]))
```

## Resource Summary

| Component | Replicas | CPU (req/limit) | Memory (req/limit) |
|-----------|----------|-----------------|-------------------|
| LLM Guard | 2 | 500m / 2 | 1Gi / 2Gi |
| NeMo Guardrails | 2 | 500m / 1 | 1Gi / 2Gi |
| **Total** | **4 pods** | **2 / 6 CPU** | **4Gi / 8Gi** |
