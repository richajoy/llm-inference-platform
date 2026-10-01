#!/usr/bin/env bash
# Install llm-d: Gateway API Inference Extension CRDs, infrastructure chart,
# InferencePool, InferenceModel CRDs, and HTTPRoute
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-inference}"

echo "==> Installing llm-d Gateway API Inference Extension"

# -----------------------------------------------------------------------------
# Step 1: Install Gateway API CRDs (if not already installed)
# -----------------------------------------------------------------------------
echo "--- Step 1: Checking Gateway API CRDs..."
if ! kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null; then
  echo "    Installing Gateway API CRDs..."
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
else
  echo "    Gateway API CRDs already installed"
fi

# -----------------------------------------------------------------------------
# Step 2: Install Inference Extension CRDs
# -----------------------------------------------------------------------------
echo "--- Step 2: Installing Inference Extension CRDs..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v0.3.0/manifests.yaml 2>/dev/null || {
  echo "    CRD manifest not found at release URL, applying from local..."
  # Fallback: the CRDs are bundled with the infra chart
  echo "    Will be installed via Helm chart"
}

# -----------------------------------------------------------------------------
# Step 3: Install the infrastructure Helm chart (EPP)
# -----------------------------------------------------------------------------
echo "--- Step 3: Installing llm-d infra chart (Endpoint Picker)..."
if helm list -n "${NAMESPACE}" | grep -q "llm-d-infra"; then
  echo "    Upgrading existing llm-d-infra release..."
  helm upgrade llm-d-infra oci://ghcr.io/kubernetes-sigs/gateway-api-inference-extension/infra \
    --namespace "${NAMESPACE}" \
    -f "${SCRIPT_DIR}/infra-chart/values.yaml" \
    --wait --timeout 120s
else
  helm install llm-d-infra oci://ghcr.io/kubernetes-sigs/gateway-api-inference-extension/infra \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    -f "${SCRIPT_DIR}/infra-chart/values.yaml" \
    --wait --timeout 120s
fi

# -----------------------------------------------------------------------------
# Step 4: Apply InferencePool and Endpoint Picker
# -----------------------------------------------------------------------------
echo "--- Step 4: Applying InferencePool..."
kubectl apply -f "${SCRIPT_DIR}/inference-pool/pool.yaml"

# Wait for EPP to be ready
echo "    Waiting for Endpoint Picker pods..."
kubectl wait --for=condition=ready pod -l app=vllm-pool-epp \
  -n "${NAMESPACE}" --timeout=120s

# -----------------------------------------------------------------------------
# Step 5: Apply InferenceModel CRDs
# -----------------------------------------------------------------------------
echo "--- Step 5: Applying InferenceModel CRDs..."
kubectl apply -f "${SCRIPT_DIR}/inference-pool/model.yaml"

# -----------------------------------------------------------------------------
# Step 6: Apply HTTPRoute
# -----------------------------------------------------------------------------
echo "--- Step 6: Applying HTTPRoute..."
kubectl apply -f "${SCRIPT_DIR}/inference-pool/httproute.yaml"

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------
echo ""
echo "==> llm-d installation complete"
echo ""
echo "Verification:"
kubectl get inferencepool -n "${NAMESPACE}" 2>/dev/null || echo "  (InferencePool CRD not yet registered)"
kubectl get inferencemodel -n "${NAMESPACE}" 2>/dev/null || echo "  (InferenceModel CRD not yet registered)"
kubectl get httproute -n "${NAMESPACE}" 2>/dev/null || echo "  (No HTTPRoutes found)"
echo ""
echo "EPP Pods:"
kubectl get pods -n "${NAMESPACE}" -l app=vllm-pool-epp
