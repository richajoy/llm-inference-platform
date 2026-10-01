# Locust Load Test for vLLM Endpoints

HTTP load testing for vLLM OpenAI-compatible chat completion endpoints with custom TTFT/TPOT metric tracking.

## Setup

```bash
pip install -r requirements.txt
```

## Usage

### Interactive (Web UI)

```bash
locust -f locustfile.py --host http://localhost:8000
```

Open http://localhost:8089 to configure users and spawn rate.

### Headless (CI/CD)

```bash
locust -f locustfile.py \
    --host http://localhost:8000 \
    --headless \
    --users 50 \
    --spawn-rate 5 \
    --run-time 5m \
    --csv results/locust-run
```

### With Custom Model

```bash
VLLM_MODEL="meta-llama/Llama-3.1-8B-Instruct" \
VLLM_MAX_TOKENS=128 \
    locust -f locustfile.py --host http://localhost:8000
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VLLM_MODEL` | `meta-llama/Llama-3.1-70B-Instruct` | Model name for requests |
| `VLLM_MAX_TOKENS` | `256` | Maximum output tokens |
| `VLLM_TEMPERATURE` | `0.7` | Sampling temperature |

## Task Weights

| Task | Weight | Description |
|------|--------|-------------|
| `chat_completion_short` | 3 | Short prompts, up to 64 tokens output |
| `chat_completion_medium` | 5 | Medium prompts, up to 256 tokens output |
| `chat_completion_long` | 1 | RAG-style long prompts, up to 512 tokens output |

## Custom Metrics

The load test tracks two additional metric types beyond standard Locust HTTP metrics:

- **TTFT (Time to First Token)**: Time from request sent to first token received via SSE streaming
- **TPOT (Time Per Output Token)**: Average inter-token latency during decoding phase

These appear as separate request types in Locust's statistics output.

## Interpreting Results

After a run, review these key numbers:

| Metric | Good | Acceptable | Poor |
|--------|------|------------|------|
| TTFT P50 | <500ms | <2000ms | >2000ms |
| TTFT P99 | <2000ms | <5000ms | >5000ms |
| TPOT P50 | <30ms | <60ms | >60ms |
| TPOT P99 | <80ms | <150ms | >150ms |
| Failure Rate | <1% | <5% | >5% |
