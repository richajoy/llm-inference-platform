# Authentication & Authorization Patterns

This document describes the authentication, authorization, and access control patterns used across the LLM inference platform.

## Overview

The platform uses a layered auth model:

```
┌──────────────────────────────────────────────────────────┐
│ Layer 4: RBAC (Teams, Users, Budgets)                    │
│ Managed by: LiteLLM                                      │
├──────────────────────────────────────────────────────────┤
│ Layer 3: API Key Authentication                          │
│ Managed by: LiteLLM Proxy                                │
├──────────────────────────────────────────────────────────┤
│ Layer 2: mTLS (Service-to-Service)                       │
│ Managed by: Kubernetes / Service Mesh                    │
├──────────────────────────────────────────────────────────┤
│ Layer 1: Network Policies                                │
│ Managed by: Kubernetes CNI                               │
└──────────────────────────────────────────────────────────┘
```

## API Key Authentication (LiteLLM)

All external access to LLM endpoints goes through LiteLLM Proxy, which authenticates requests using API keys.

### Key Hierarchy

```
Master Key (admin operations only)
  └── Organization
        └── Team (shared budget + model access)
              └── User (individual budget)
                    └── API Key (scoped permissions, expiry)
```

### Generating Keys

```bash
export MASTER_KEY="sk-master-changeme"
export LITELLM_URL="http://litellm.enterprise.svc.cluster.local:4000"

# Create a team
TEAM_ID=$(curl -s -X POST "$LITELLM_URL/team/new" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_alias": "ml-engineering",
    "max_budget": 500.0,
    "budget_duration": "monthly",
    "models": ["llama-3.1-8b", "llama-3.3-70b", "llama-3.3-70b-fp8"],
    "tpm_limit": 1000000,
    "rpm_limit": 600
  }' | jq -r '.team_id')

# Create a user
USER_ID=$(curl -s -X POST "$LITELLM_URL/user/new" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "user_email": "engineer@company.com",
    "user_role": "internal_user",
    "team_id": "'$TEAM_ID'",
    "max_budget": 100.0
  }' | jq -r '.user_id')

# Generate an API key
curl -X POST "$LITELLM_URL/key/generate" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_id": "'$TEAM_ID'",
    "user_id": "'$USER_ID'",
    "key_alias": "dev-laptop",
    "models": ["llama-3.1-8b"],
    "max_budget": 25.0,
    "duration": "30d"
  }'
```

### Key Scoping

API keys can be restricted at creation time:

| Scope | Description | Example |
|-------|-------------|---------|
| `models` | Which models the key can access | `["llama-3.1-8b"]` |
| `max_budget` | Maximum spend for this key | `25.0` (dollars) |
| `duration` | Key expiry time | `"30d"`, `"7d"`, `"24h"` |
| `tpm_limit` | Tokens per minute for this key | `100000` |
| `rpm_limit` | Requests per minute for this key | `60` |
| `allowed_ips` | IP allowlist (if configured) | `["10.0.0.0/8"]` |

## OIDC Integration

For enterprise SSO, LiteLLM supports OIDC providers (Okta, Azure AD, Google Workspace).

### Configuration Pattern

Add to the LiteLLM config:

```yaml
general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/LITELLM_DATABASE_URL
  # OIDC SSO configuration
  ui_access_mode: "sso_only"
  default_team_disabled: true
  sso_enabled: true

environment_variables:
  GOOGLE_CLIENT_ID: os.environ/GOOGLE_CLIENT_ID
  GOOGLE_CLIENT_SECRET: os.environ/GOOGLE_CLIENT_SECRET
  PROXY_BASE_URL: "https://llm-gateway.company.com"
```

### SSO Flow

1. User accesses the LiteLLM UI or API
2. Redirected to OIDC provider for authentication
3. On success, LiteLLM creates/maps the user to a team
4. User receives a session token or generates an API key
5. Subsequent API requests use the key as a Bearer token

### Supported Providers

- **Google Workspace**: `GOOGLE_CLIENT_ID` + `GOOGLE_CLIENT_SECRET`
- **Microsoft Azure AD**: `AZURE_CLIENT_ID` + `AZURE_CLIENT_SECRET` + `AZURE_TENANT_ID`
- **Okta**: `GENERIC_CLIENT_ID` + `GENERIC_CLIENT_SECRET` + `GENERIC_AUTHORIZATION_ENDPOINT`
- **Any OIDC provider**: Via generic OIDC configuration

## mTLS for Service-to-Service Communication

Internal services (LiteLLM <-> vLLM, LiteLLM <-> Guardrails) use mTLS for encrypted, authenticated communication.

### Without Service Mesh

Use Kubernetes-native cert-manager:

```yaml
# cert-manager Certificate resource
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: litellm-tls
  namespace: enterprise
spec:
  secretName: litellm-tls-cert
  issuerRef:
    name: cluster-issuer
    kind: ClusterIssuer
  dnsNames:
    - litellm.enterprise.svc.cluster.local
    - litellm.enterprise.svc
  duration: 8760h  # 1 year
  renewBefore: 720h  # 30 days
```

### With Istio Service Mesh

Istio provides automatic mTLS between all meshed services:

```yaml
# PeerAuthentication: require mTLS in the enterprise namespace
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: enterprise-mtls
  namespace: enterprise
spec:
  mtls:
    mode: STRICT
```

### Network Policies

Restrict which services can communicate:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: litellm-ingress
  namespace: enterprise
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: litellm
  policyTypes:
    - Ingress
  ingress:
    # Allow from gateway namespace (external traffic)
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: gateway
      ports:
        - port: 4000
    # Allow from monitoring namespace (Prometheus scraping)
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - port: 4000
```

## RBAC Model

### Roles

| Role | Permissions | Typical User |
|------|------------|--------------|
| `proxy_admin` | Full access, manage teams/users/keys | Platform team |
| `internal_user` | Use assigned models within budget | Engineers |
| `internal_user_viewer` | Read-only access, no inference | Auditors |

### Team-Based Access Control

Teams define the boundary for:
- **Model access**: Which models team members can use
- **Budget**: Shared monthly/daily spend limit
- **Rate limits**: Aggregate RPM/TPM for the team
- **Members**: Users assigned to the team

### Budget Enforcement

```
Request → Check Key Budget → Check User Budget → Check Team Budget → Allow/Deny
```

When any budget is exceeded, the request is rejected with HTTP 429 and a message indicating which budget was hit.

### Audit Trail

All requests are logged in PostgreSQL with:
- Timestamp
- User ID and team ID
- API key hash (not the key itself)
- Model used
- Token count (input + output)
- Latency
- Status code

Query the audit log:

```bash
# Via LiteLLM API
curl "$LITELLM_URL/spend/logs?start_date=2026-02-01&end_date=2026-02-28" \
  -H "Authorization: Bearer $MASTER_KEY"

# Or directly via PostgreSQL
kubectl -n enterprise exec -it deploy/postgres -- \
  psql -U litellm -c "SELECT * FROM spend_logs ORDER BY created_at DESC LIMIT 20;"
```

## Security Best Practices

1. **Never use default secrets in production** -- Replace all `changeme` values with strong, unique secrets using SealedSecrets or external-secrets-operator
2. **Rotate API keys regularly** -- Set key `duration` and automate rotation
3. **Use least-privilege model access** -- Only grant models that a team actually needs
4. **Enable network policies** -- Restrict pod-to-pod communication to only what is required
5. **Monitor spend and usage** -- Set up alerts for unusual spending patterns
6. **Use OIDC for human users** -- API keys for service accounts, SSO for humans
7. **Audit regularly** -- Review spend logs and key usage monthly
