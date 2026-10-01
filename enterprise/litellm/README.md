# LiteLLM API Gateway

LiteLLM Proxy provides an OpenAI-compatible API gateway with authentication, RBAC, rate limiting, budget management, and model routing across all vLLM backends.

## Architecture

```
Client Request
    │
    ▼
┌──────────────────────────────────────┐
│  LiteLLM Proxy (:4000)              │
│  ┌──────────┐  ┌──────────────────┐ │
│  │ Auth/RBAC │  │ Rate Limiter     │ │
│  │ (Postgres)│  │ (Redis)          │ │
│  └──────────┘  └──────────────────┘ │
│  ┌──────────────────────────────────┐│
│  │ Model Router (least-busy)       ││
│  └──────────────────────────────────┘│
└──────────┬──────────┬──────────┬─────┘
           │          │          │
     ┌─────▼──┐ ┌────▼───┐ ┌───▼──────┐
     │vLLM 8B │ │vLLM 70B│ │vLLM FP8  │
     │ :8000  │ │ :8000  │ │ :8000    │
     └────────┘ └────────┘ └──────────┘
```

## Deployment

### Prerequisites

1. Enterprise namespace exists (created by postgres.yaml)
2. At least one vLLM backend running in the `inference` namespace
3. Update secrets in `deployment.yaml` before production use

### Deploy

```bash
# 1. Deploy PostgreSQL (stores teams, keys, budgets)
kubectl apply -f enterprise/litellm/postgres.yaml

# 2. Deploy Redis (rate limiting + response caching)
kubectl apply -f enterprise/litellm/redis.yaml

# 3. Wait for dependencies
kubectl -n enterprise wait --for=condition=ready pod -l app.kubernetes.io/name=postgres --timeout=120s
kubectl -n enterprise wait --for=condition=ready pod -l app.kubernetes.io/name=redis --timeout=60s

# 4. Deploy LiteLLM config and proxy
kubectl apply -f enterprise/litellm/config.yaml
kubectl apply -f enterprise/litellm/deployment.yaml
kubectl apply -f enterprise/litellm/service.yaml

# 5. Verify
kubectl -n enterprise get pods
kubectl -n enterprise logs -l app.kubernetes.io/name=litellm --tail=50
```

### Verify Health

```bash
# Port-forward for local access
kubectl -n enterprise port-forward svc/litellm 4000:4000

# Check health
curl http://localhost:4000/health/readiness

# List models
curl http://localhost:4000/v1/models \
  -H "Authorization: Bearer sk-master-changeme-use-sealed-secrets"
```

## Team & User Management

LiteLLM uses a hierarchical RBAC model: **Organizations > Teams > Users > API Keys**.

### Create a Team

Teams group users and share a budget pool.

```bash
export MASTER_KEY="sk-master-changeme-use-sealed-secrets"
export LITELLM_URL="http://localhost:4000"

curl -X POST "$LITELLM_URL/team/new" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_alias": "engineering",
    "max_budget": 100.0,
    "budget_duration": "monthly",
    "models": ["llama-3.1-8b", "llama-3.3-70b"],
    "tpm_limit": 500000,
    "rpm_limit": 300
  }'
```

### Create a User

```bash
curl -X POST "$LITELLM_URL/user/new" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "user_email": "dev@example.com",
    "user_role": "internal_user",
    "team_id": "<team-id-from-above>",
    "max_budget": 25.0
  }'
```

### Generate an API Key

```bash
curl -X POST "$LITELLM_URL/key/generate" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_id": "<team-id>",
    "user_id": "<user-id>",
    "key_alias": "dev-workstation",
    "models": ["llama-3.1-8b"],
    "max_budget": 10.0,
    "duration": "30d"
  }'
```

### Use the Key

```bash
export API_KEY="sk-<generated-key>"

curl "$LITELLM_URL/v1/chat/completions" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama-3.1-8b",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 128
  }'
```

## Rate Limiting

Rate limits are enforced at multiple levels (most restrictive wins):

| Level | Config Field | Example |
|-------|-------------|---------|
| Model | `rpm` / `tpm` in model_list | 600 RPM for 8B |
| Team | `tpm_limit` / `rpm_limit` on team | 500K TPM shared |
| User | `max_budget` on user | $25/month |
| Key | `max_budget` / `duration` on key | $10 for 30 days |

When a limit is hit, LiteLLM returns HTTP 429 with a `Retry-After` header.

## Budget Management

Budgets are tracked in PostgreSQL and reset based on `budget_duration`:

```bash
# Check team spend
curl "$LITELLM_URL/team/info?team_id=<team-id>" \
  -H "Authorization: Bearer $MASTER_KEY"

# Check user spend
curl "$LITELLM_URL/user/info?user_id=<user-id>" \
  -H "Authorization: Bearer $MASTER_KEY"

# Update team budget
curl -X POST "$LITELLM_URL/team/update" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_id": "<team-id>",
    "max_budget": 200.0
  }'
```

## Model Access Control

Restrict which models a team or key can access:

```bash
# Team-level: only allow 8B model
curl -X POST "$LITELLM_URL/team/new" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_alias": "cost-conscious-team",
    "models": ["llama-3.1-8b"],
    "max_budget": 50.0
  }'

# Key-level: further restrict within team allowances
curl -X POST "$LITELLM_URL/key/generate" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_id": "<team-id>",
    "models": ["llama-3.1-8b"],
    "max_budget": 5.0
  }'
```

## Monitoring

LiteLLM exports Prometheus metrics on `/metrics`:

| Metric | Description |
|--------|-------------|
| `litellm_requests_total` | Total requests by model, status |
| `litellm_request_duration_seconds` | Latency histogram |
| `litellm_tokens_total` | Token usage by model, direction |
| `litellm_budget_remaining` | Remaining budget by team |
| `litellm_rate_limit_hits_total` | Rate limit rejections |

These are scraped automatically by the platform Prometheus instance via pod annotations.

## Configuration Reference

The proxy config is in `config.yaml` (ConfigMap). Key sections:

- **model_list**: Maps friendly model names to vLLM backend URLs with per-model rate limits
- **general_settings**: Master key, database URL, alerting
- **litellm_settings**: Caching, callbacks, timeouts, retries
- **router_settings**: Load balancing strategy across backends

## Production Checklist

- [ ] Replace all secrets with SealedSecrets or external-secrets-operator
- [ ] Configure TLS termination at ingress/gateway level
- [ ] Set up Slack webhook for budget and error alerts
- [ ] Enable audit logging for compliance
- [ ] Configure backup for PostgreSQL PVC
- [ ] Set appropriate budget limits per team
- [ ] Test failover when a vLLM backend is unavailable
