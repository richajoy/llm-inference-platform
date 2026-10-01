# k6 Load Test for vLLM Endpoints

Threshold-based load testing for vLLM OpenAI-compatible chat completion endpoints with CI/CD-friendly output.

## Prerequisites

Install k6: https://grafana.com/docs/k6/latest/set-up/install-k6/

```bash
# macOS
brew install k6

# Linux
sudo apt-get install k6
```

## Usage

### Basic Run

```bash
k6 run chat-completion.js
```

### Custom Endpoint

```bash
k6 run --env VLLM_HOST=http://my-vllm-service:8000 chat-completion.js
```

### Custom Configuration

```bash
k6 run \
    --env VLLM_HOST=http://localhost:8000 \
    --env VLLM_MODEL=meta-llama/Llama-3.1-8B-Instruct \
    --env VLLM_MAX_TOKENS=128 \
    chat-completion.js
```

### Override Stages

```bash
k6 run --stage 30s:5,2m:20,30s:0 chat-completion.js
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VLLM_HOST` | `http://localhost:8000` | vLLM endpoint URL |
| `VLLM_MODEL` | `meta-llama/Llama-3.1-70B-Instruct` | Model name |
| `VLLM_MAX_TOKENS` | `256` | Max output tokens |

## Default Load Profile

| Phase | Duration | Virtual Users |
|-------|----------|---------------|
| Ramp up | 1 min | 0 -> 10 |
| Sustain | 3 min | 50 |
| Ramp down | 1 min | 50 -> 0 |

## Thresholds (Pass/Fail)

| Metric | Threshold | Description |
|--------|-----------|-------------|
| TTFT P50 | < 2000ms | Median time to first token |
| TTFT P99 | < 5000ms | 99th percentile TTFT |
| TPOT P50 | < 60ms | Median time per output token |
| TPOT P99 | < 100ms | 99th percentile TPOT |
| HTTP error rate | < 5% | Request failures |
| Stream error rate | < 10% | SSE parsing failures |

## CI/CD Integration

k6 exits with code 99 if thresholds are violated:

```bash
k6 run chat-completion.js || echo "Performance regression detected!"
```

Results are saved to `results/k6-summary.json` for downstream processing.

### GitHub Actions Example

```yaml
- name: Run k6 load test
  run: |
    k6 run --env VLLM_HOST=${{ env.ENDPOINT }} benchmarks/k6/chat-completion.js
```

## Limitations

k6 does not support true HTTP streaming (SSE). The test receives the full response body after completion, so TTFT and TPOT are estimated rather than measured precisely. For accurate streaming metrics, use the Locust load test (`benchmarks/locust/`) which supports incremental response parsing.
