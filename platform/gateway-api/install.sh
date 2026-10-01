#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="gateway"
ENVOY_GATEWAY_VERSION="v1.2.4"
GATEWAY_API_VERSION="v1.2.1"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install Gateway API CRDs and Envoy Gateway controller.

Options:
  --envoy-version   Envoy Gateway version (default: $ENVOY_GATEWAY_VERSION)
  --crd-version     Gateway API CRD version (default: $GATEWAY_API_VERSION)
  --dry-run         Render templates without installing
  -h, --help        Show this help message
EOF
}

DRY_RUN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --envoy-version)
      ENVOY_GATEWAY_VERSION="$2"
      shift 2
      ;;
    --crd-version)
      GATEWAY_API_VERSION="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="--dry-run=client"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

echo "=== Installing Gateway API + Envoy Gateway ==="
echo "  Namespace:              $NAMESPACE"
echo "  Gateway API CRD:        $GATEWAY_API_VERSION"
echo "  Envoy Gateway:          $ENVOY_GATEWAY_VERSION"

# ---- Step 1: Gateway API CRDs ----
echo ""
echo "--- Step 1/4: Installing Gateway API CRDs ---"

kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" $DRY_RUN
echo "  Gateway API CRDs installed."

# ---- Step 2: Create namespace ----
echo ""
echo "--- Step 2/4: Creating namespace ---"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Label namespaces for route access
for ns in inference enterprise; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "$ns" gateway-access=true --overwrite
done
echo "  Namespaces labeled for gateway access."

# ---- Step 3: Install Envoy Gateway ----
echo ""
echo "--- Step 3/4: Installing Envoy Gateway ---"

helm repo add envoy-gateway https://gateway.envoyproxy.io/helm-charts 2>/dev/null || true
helm repo update envoy-gateway

helm upgrade --install envoy-gateway envoy-gateway/gateway-helm \
  --namespace "$NAMESPACE" \
  --version "$ENVOY_GATEWAY_VERSION" \
  --wait \
  --timeout 5m \
  ${DRY_RUN:+--dry-run}

echo "  Envoy Gateway controller installed."

# ---- Step 4: Apply Gateway resources ----
echo ""
echo "--- Step 4/4: Applying Gateway resources ---"

kubectl apply -f "${SCRIPT_DIR}/gateway-class.yaml"
kubectl apply -f "${SCRIPT_DIR}/gateway.yaml"

echo "  GatewayClass and Gateway created."

echo ""
echo "=== Gateway API Installation Complete ==="
echo ""
echo "Verify with:"
echo "  kubectl get gatewayclass"
echo "  kubectl get gateway -n $NAMESPACE"
echo "  kubectl get pods -n $NAMESPACE"
echo ""
echo "To get the external IP:"
echo "  kubectl get svc -n $NAMESPACE -l gateway.networking.k8s.io/owning-gateway-name=llm-gateway"
echo ""
echo "Next steps:"
echo "  1. Create HTTPRoute resources in inference/enterprise namespaces"
echo "  2. Configure TLS certificate in secret 'llm-gateway-tls'"
