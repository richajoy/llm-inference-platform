#!/usr/bin/env bash
# Install NVIDIA Dynamo for disaggregated LLM inference
# Provides Smart Router + NIXL-based P/D serving
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-inference}"

echo "==> Installing NVIDIA Dynamo"

# -----------------------------------------------------------------------------
# Step 1: Add Dynamo Helm repository
# -----------------------------------------------------------------------------
echo "--- Step 1: Adding Dynamo Helm repo..."
helm repo add dynamo https://helm.dynamo.nvidia.com 2>/dev/null || true
helm repo update dynamo

# -----------------------------------------------------------------------------
# Step 2: Apply disaggregated P/D ConfigMap
# -----------------------------------------------------------------------------
echo "--- Step 2: Applying disaggregated P/D config..."
kubectl apply -f "${SCRIPT_DIR}/disagg-config.yaml"

# -----------------------------------------------------------------------------
# Step 3: Install Dynamo Helm chart
# -----------------------------------------------------------------------------
echo "--- Step 3: Installing Dynamo Helm chart..."
if helm list -n "${NAMESPACE}" | grep -q "dynamo"; then
  echo "    Upgrading existing Dynamo release..."
  helm upgrade dynamo dynamo/dynamo \
    --namespace "${NAMESPACE}" \
    -f "${SCRIPT_DIR}/values.yaml" \
    --wait --timeout 300s
else
  helm install dynamo dynamo/dynamo \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    -f "${SCRIPT_DIR}/values.yaml" \
    --wait --timeout 300s
fi

# -----------------------------------------------------------------------------
# Step 4: Verify deployment
# -----------------------------------------------------------------------------
echo ""
echo "==> Dynamo installation complete"
echo ""
echo "Pods:"
kubectl get pods -n "${NAMESPACE}" -l app=dynamo
echo ""
echo "Services:"
kubectl get svc -n "${NAMESPACE}" -l app=dynamo
echo ""
echo "Smart Router endpoint:"
echo "  http://dynamo-smart-router.${NAMESPACE}:8000"
echo ""
echo "To test:"
echo "  kubectl run curl --rm -it --image=curlimages/curl -- \\"
echo "    curl -s http://dynamo-smart-router.${NAMESPACE}:8000/v1/models | jq ."
