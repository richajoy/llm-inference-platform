#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install the entire Kubernetes platform layer in the correct order:
  1. GPU Operator (driver, toolkit, DCGM, MIG manager)
  2. Network Operator (InfiniBand/RDMA - skipped on RunPod)
  3. Monitoring (Prometheus, Grafana, DCGM Exporter, dashboards, alerts)
  4. Gateway API (CRDs + Envoy Gateway)
  5. Autoscaling (KEDA operator)

Options:
  --mig-single        Enable MIG with single strategy
  --mig-mixed         Enable MIG with mixed strategy
  --skip-network      Skip Network Operator installation
  --skip-autoscaling  Skip KEDA/autoscaling installation
  --grafana-password  Grafana admin password (default: env GRAFANA_ADMIN_PASSWORD)
  --dry-run           Render templates without installing
  -h, --help          Show this help message
EOF
}

MIG_FLAG=""
SKIP_NETWORK=false
SKIP_AUTOSCALING=false
GRAFANA_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
DRY_RUN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mig-single)
      MIG_FLAG="--mig-single"
      shift
      ;;
    --mig-mixed)
      MIG_FLAG="--mig-mixed"
      shift
      ;;
    --skip-network)
      SKIP_NETWORK=true
      shift
      ;;
    --skip-autoscaling)
      SKIP_AUTOSCALING=true
      shift
      ;;
    --grafana-password)
      GRAFANA_PASSWORD="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="--dry-run"
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

echo "============================================"
echo "  Enterprise LLM Platform - Full Install"
echo "============================================"
echo ""
echo "Components:"
echo "  [1] GPU Operator        ${MIG_FLAG:-(no MIG)}"
echo "  [2] Network Operator    $(if [[ "$SKIP_NETWORK" == "true" ]]; then echo "SKIP"; else echo "enabled"; fi)"
echo "  [3] Monitoring Stack    enabled"
echo "  [4] Gateway API         enabled"
echo "  [5] Autoscaling (KEDA)  $(if [[ "$SKIP_AUTOSCALING" == "true" ]]; then echo "SKIP"; else echo "enabled"; fi)"
echo ""

# Verify kubectl access
echo "--- Checking cluster access ---"
if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: Cannot connect to Kubernetes cluster. Check your kubeconfig."
  exit 1
fi
echo "  Cluster: $(kubectl cluster-info 2>&1 | head -1)"
echo ""

# ============================================
# Step 1: GPU Operator
# ============================================
echo "============================================"
echo "  [1/5] GPU Operator"
echo "============================================"
bash "${SCRIPT_DIR}/gpu-operator/install.sh" $MIG_FLAG $DRY_RUN
echo ""

# ============================================
# Step 2: Network Operator
# ============================================
echo "============================================"
echo "  [2/5] Network Operator"
echo "============================================"
if [[ "$SKIP_NETWORK" == "true" ]]; then
  echo "  Skipped (--skip-network)"
else
  bash "${SCRIPT_DIR}/network-operator/install.sh" $DRY_RUN
fi
echo ""

# ============================================
# Step 3: Monitoring Stack
# ============================================
echo "============================================"
echo "  [3/5] Monitoring Stack"
echo "============================================"
GRAFANA_ADMIN_PASSWORD="$GRAFANA_PASSWORD" bash "${SCRIPT_DIR}/monitoring/install.sh" $DRY_RUN
echo ""

# ============================================
# Step 4: Gateway API
# ============================================
echo "============================================"
echo "  [4/5] Gateway API"
echo "============================================"
bash "${SCRIPT_DIR}/gateway-api/install.sh" $DRY_RUN
echo ""

# ============================================
# Step 5: Autoscaling (KEDA)
# ============================================
echo "============================================"
echo "  [5/5] Autoscaling (KEDA)"
echo "============================================"
if [[ "$SKIP_AUTOSCALING" == "true" ]]; then
  echo "  Skipped (--skip-autoscaling)"
else
  bash "${SCRIPT_DIR}/autoscaling/keda-install.sh" $DRY_RUN

  echo ""
  echo "  Installing Prometheus Adapter..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo update prometheus-community
  helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
    --namespace monitoring \
    -f "${SCRIPT_DIR}/autoscaling/prometheus-adapter/values.yaml" \
    --wait \
    --timeout 5m \
    $DRY_RUN
fi
echo ""

# ============================================
# Summary
# ============================================
echo "============================================"
echo "  Platform Installation Complete"
echo "============================================"
echo ""
echo "Namespaces created:"
kubectl get namespaces -l 'kubernetes.io/metadata.name in (gpu-operator,monitoring,gateway,inference,enterprise,keda)' --no-headers 2>/dev/null || true
echo ""
echo "Quick health check:"
echo "  kubectl get pods -n gpu-operator"
echo "  kubectl get pods -n monitoring"
echo "  kubectl get pods -n gateway"
if [[ "$SKIP_AUTOSCALING" == "false" ]]; then
  echo "  kubectl get pods -n keda"
fi
echo ""
echo "Access Grafana:"
echo "  kubectl port-forward svc/kube-prometheus-stack-grafana 3000:3000 -n monitoring"
echo "  URL: http://localhost:3000  (admin / <configured-password>)"
echo ""
echo "Next steps:"
echo "  1. Deploy inference workloads: make deploy-70b-tp4"
echo "  2. Deploy enterprise services: make deploy-enterprise"
echo "  3. Apply autoscaling policies: kubectl apply -f platform/autoscaling/keda-vllm.yaml"
