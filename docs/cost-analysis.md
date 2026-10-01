# Cost Analysis

## Cloud GPU Pricing Comparison

### RunPod

| Configuration | GPU | On-Demand ($/hr) | Spot ($/hr) | Notes |
|--------------|-----|-------------------|-------------|-------|
| 1xH100 SXM 80GB | H100 | $2.69 | ~$1.89 | Single GPU |
| 8xH100 SXM 80GB | H100 | $21.52 | ~$15.06 | Full node, NVLink |
| 1xA100 SXM 80GB | A100 | $1.64 | ~$1.15 | Previous gen |
| 8xA100 SXM 80GB | A100 | $13.12 | ~$9.18 | Full node |
| 1xH200 SXM 141GB | H200 | $3.99 | ~$2.79 | When available |

RunPod pricing is per-GPU-hour. The 8xH100 node is the primary development target for this platform.

**Disk storage**: $0.07/GB/month for persistent volume (500 GB = $35/month)

### Google Cloud (GKE)

| Machine Type | GPUs | On-Demand ($/hr) | 1yr CUD ($/hr) | 3yr CUD ($/hr) |
|-------------|------|-------------------|-----------------|-----------------|
| a3-highgpu-8g | 8xH100 80GB | $31.21 | $19.97 | $14.05 |
| a3-ultragpu-8g | 8xH200 141GB | $40.22 | $25.74 | $18.10 |
| a2-ultragpu-8g | 8xA100 80GB | $21.40 | $13.70 | $9.63 |

GKE adds:
- **GKE cluster fee**: $0.10/hr for Standard, $0.00 for Autopilot
- **Networking**: Egress charged at $0.08-$0.12/GB
- **Storage**: Persistent Disk at $0.04/GB/month (SSD)

### AWS (EKS)

| Instance Type | GPUs | On-Demand ($/hr) | 1yr RI ($/hr) | 3yr RI ($/hr) |
|--------------|------|-------------------|---------------|---------------|
| p5.48xlarge | 8xH100 80GB | $98.32 | $62.12 | $39.88 |
| p4d.24xlarge | 8xA100 40GB | $32.77 | $20.70 | $13.29 |
| p5e.48xlarge | 8xH200 141GB | ~$115.00 | ~$72.68 | ~$46.68 |

AWS pricing is significantly higher than RunPod due to enterprise features (SLAs, compliance, networking).

## Cost Per 1M Tokens

### Methodology

Cost per 1M tokens = (GPU-hours per 1M tokens) x ($/GPU-hour)

Assumptions:
- Average input length: 500 tokens
- Average output length: 200 tokens
- 70% GPU utilization (realistic for interactive serving)

### Profile A: Llama 8B on MIG (1g.10gb)

```
Decode throughput: ~84 tok/s per MIG instance
Effective (70% util): ~59 tok/s
Tokens per hour: 212,400

GPU cost per MIG instance: $21.52/hr / 56 instances = $0.384/hr
Cost per 1M tokens: $0.384 / 0.2124M = $1.81
```

### Profile B: Llama 70B TP=4 (FP16)

```
Decode throughput: ~24 tok/s per request (B=1)
With batching (avg B=8): ~190 tok/s aggregate
Effective (70% util): ~133 tok/s
Tokens per hour: 478,800

GPU cost: 4 GPUs x $2.69/hr = $10.76/hr (RunPod)
Cost per 1M tokens: $10.76 / 0.4788M = $22.47
```

### Profile C: Llama 70B FP8 TP=2

```
Decode throughput: ~47 tok/s per request (B=1)
With batching (avg B=8): ~376 tok/s aggregate
Effective (70% util): ~263 tok/s
Tokens per hour: 946,800

GPU cost: 2 GPUs x $2.69/hr = $5.38/hr (RunPod)
Cost per 1M tokens: $5.38 / 0.9468M = $5.68
```

### Profile D: Llama 70B + EAGLE3 TP=4

```
Decode throughput: ~72 tok/s per request (B=1, 3x from EAGLE3)
With batching (avg B=4): ~230 tok/s aggregate
Effective (70% util): ~161 tok/s
Tokens per hour: 579,600

GPU cost: 4 GPUs x $2.69/hr = $10.76/hr (RunPod)
Cost per 1M tokens: $10.76 / 0.5796M = $18.56

Note: EAGLE3 improves per-request latency but aggregate throughput
at high batch is comparable to Profile B.
```

### Profile E: Llama 70B Disaggregated P/D

```
Prefill pod (4 GPUs): Handles prompt processing
Decode pod (4 GPUs): Handles token generation

Combined throughput (optimized): ~250 tok/s aggregate
Effective (70% util): ~175 tok/s
Tokens per hour: 630,000

GPU cost: 8 GPUs x $2.69/hr = $21.52/hr (RunPod)
Cost per 1M tokens: $21.52 / 0.630M = $34.16

Note: Higher cost per token but optimized for latency SLAs
under high concurrency.
```

### Summary: Cost per 1M Output Tokens

| Profile | Model | GPUs | RunPod $/1M tok | GKE $/1M tok | Best For |
|---------|-------|------|-----------------|--------------|----------|
| A (MIG) | 8B FP8 | 1 MIG | $1.81 | $2.46 | Simple tasks, high volume |
| B (TP4) | 70B FP16 | 4 | $22.47 | $30.56 | Quality baseline |
| C (FP8) | 70B FP8 | 2 | $5.68 | $7.72 | Best quality/cost |
| D (EAGLE3) | 70B FP16 | 4 | $18.56 | $25.24 | Low latency |
| E (Disagg) | 70B FP16 | 8 | $34.16 | $46.46 | Latency SLAs at scale |

Profile C (FP8 on 2 GPUs) offers the best cost efficiency for 70B-class models, at 4x cheaper than Profile B with minimal quality impact.

## Break-Even Analysis: RunPod vs Cloud

### Monthly Cost Comparison (8xH100, 24/7)

| Provider | Pricing Model | Monthly Cost |
|----------|---------------|-------------|
| RunPod | On-demand | $15,494/mo |
| RunPod | Spot (~30% off) | $10,843/mo |
| GKE | On-demand | $22,471/mo |
| GKE | 1yr CUD | $14,378/mo |
| GKE | 3yr CUD | $10,116/mo |
| AWS | On-demand | $70,790/mo |
| AWS | 1yr RI | $44,726/mo |
| AWS | 3yr RI | $28,714/mo |

### When RunPod Makes Sense

- **Development and experimentation**: Short-term, flexible, no commitment
- **Cost-sensitive workloads**: 30-50% cheaper than cloud on-demand
- **Simple deployments**: Single-node, no multi-region requirements
- **Proof of concept**: Quick spin-up, quick tear-down

### When GKE Makes Sense

- **Production SLAs**: 99.9% uptime SLA with financial backing
- **Multi-region**: Automatic failover across zones
- **Enterprise compliance**: SOC2, HIPAA, FedRAMP
- **Managed Kubernetes**: Automatic upgrades, node management
- **Long-term commitment**: 3yr CUD pricing competitive with RunPod

### When AWS Makes Sense

- **Existing AWS ecosystem**: Integration with other AWS services
- **Capacity reservations**: Guaranteed GPU capacity for critical workloads
- **Enterprise contracts**: Volume discounts through EDP
- **Multi-cloud strategy**: Paired with GKE or Azure for redundancy

## Cost Optimization Strategies

### 1. Use FP8 Quantization

FP8 halves GPU requirements for the same model quality:
- Llama 70B FP16: 4 GPUs ($10.76/hr)
- Llama 70B FP8: 2 GPUs ($5.38/hr)
- **Savings: 50%**

### 2. MIG for Small Models

Run 7 Llama 8B instances on 1 GPU instead of 7 GPUs:
- Without MIG: 7 GPUs ($18.83/hr)
- With MIG: 1 GPU ($2.69/hr)
- **Savings: 86%**

### 3. Spot/Preemptible Instances

Use spot pricing for non-critical workloads:
- RunPod spot: ~30% savings
- GKE preemptible: ~60-70% savings
- **Risk**: Instance can be reclaimed with 30s notice

### 4. Right-Size GPU Selection

Match the GPU to the workload:
- Llama 8B does not need H100 -- consider A100 or MIG slice
- Llama 70B FP8 fits on 1 H200 (141 GB) -- avoid 4-GPU TP setup

### 5. Autoscaling

Scale down during low-traffic periods:
- Use HPA/KEDA to scale vLLM replicas to zero during off-hours
- For RunPod: Terraform can destroy/recreate pods on schedule
- **Savings: 50-70%** if traffic has strong diurnal patterns

### 6. Batching Optimization

Higher batch sizes increase throughput without additional GPUs:
- B=1: ~24 tok/s (Llama 70B, H100)
- B=32: ~762 tok/s (32x throughput, same 4 GPUs)
- Configure `--max-num-seqs` to maximize batching

### 7. Prefix Caching

If many requests share the same system prompt:
- Without prefix caching: Re-process 500-token system prompt each request
- With prefix caching: Process system prompt once, reuse KV cache
- **Savings**: Proportional to system prompt length vs total prompt

## Total Cost of Ownership (TCO)

### Monthly TCO for a Production Deployment

| Component | RunPod (Dev) | GKE (Prod) |
|-----------|-------------|------------|
| Compute (8xH100, 24/7) | $15,494 | $14,378 (1yr CUD) |
| Storage (500 GB SSD) | $35 | $20 |
| Networking (1 TB egress) | Included | $85 |
| Monitoring (Prometheus) | Included (self-hosted) | $0 (self-hosted) |
| GKE management fee | N/A | $73 |
| Support | Community | $0-$500 (GCP support tier) |
| **Total** | **~$15,529/mo** | **~$14,556/mo** |

### Per-Request Cost at Scale

Assuming 10M requests/day, average 200 output tokens/request:

```
Total output tokens/day = 10M x 200 = 2B tokens
Total output tokens/month = 60B tokens

Using Profile C (FP8, $5.68/1M tokens):
Monthly inference cost = 60,000 x $5.68 = $340,800

Cost per request = $340,800 / 300M = $0.00114 (~$1.14 per 1000 requests)
```

For comparison, OpenAI GPT-4o charges $5.00/1M output tokens, making self-hosted inference approximately $5.00 / $5.68 = 0.88x the cost of OpenAI at this scale, before accounting for higher utilization and batching that self-hosting enables.
