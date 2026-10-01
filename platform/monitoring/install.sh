#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="monitoring"
PROM_CHART_VERSION="65.3.1"
DCGM_CHART_VERSION="3.3.8"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install the full monitoring stack: Prometheus, Grafana, DCGM Exporter, dashboards, alerts.

Options:
  --grafana-password  Grafana admin password (default: from GRAFANA_ADMIN_PASSWORD env var)
  --skip-dashboards   Skip dashboard ConfigMap creation
  --skip-alerts       Skip PrometheusRule creation
  --dry-run           Render templates without installing
  -h, --help          Show this help message
EOF
}

DRY_RUN=""
SKIP_DASHBOARDS=false
SKIP_ALERTS=false
GRAFANA_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --grafana-password)
      GRAFANA_PASSWORD="$2"
      shift 2
      ;;
    --skip-dashboards)
      SKIP_DASHBOARDS=true
      shift
      ;;
    --skip-alerts)
      SKIP_ALERTS=true
      shift
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

echo "=== Installing Monitoring Stack ==="
echo "  Namespace: $NAMESPACE"

# Create namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ---- Step 1: kube-prometheus-stack ----
echo ""
echo "--- Step 1/4: Installing kube-prometheus-stack ---"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update prometheus-community

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace "$NAMESPACE" \
  --version "$PROM_CHART_VERSION" \
  -f "${SCRIPT_DIR}/kube-prometheus-stack/values.yaml" \
  --set grafana.adminPassword="$GRAFANA_PASSWORD" \
  --wait \
  --timeout 10m \
  $DRY_RUN

echo "  Prometheus + Grafana installed."

# ---- Step 2: DCGM Exporter (standalone, if not via GPU Operator) ----
echo ""
echo "--- Step 2/4: Checking DCGM Exporter ---"

# Check if DCGM is already running via GPU Operator
if kubectl get daemonset -n gpu-operator nvidia-dcgm-exporter 2>/dev/null; then
  echo "  DCGM Exporter already running via GPU Operator. Skipping standalone install."
  echo "  Ensuring ServiceMonitor exists for GPU Operator DCGM..."
  cat <<EOSM | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: dcgm-exporter
  namespace: $NAMESPACE
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - gpu-operator
  selector:
    matchLabels:
      app: nvidia-dcgm-exporter
  endpoints:
    - port: gpu-metrics
      interval: 15s
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_node_name]
          targetLabel: node
EOSM
else
  echo "  No GPU Operator DCGM found. Installing standalone DCGM Exporter."
  kubectl apply -f "${SCRIPT_DIR}/dcgm-exporter/dcgm-metrics-configmap.yaml"
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>/dev/null || true
  helm repo update nvidia
  helm upgrade --install dcgm-exporter nvidia/dcgm-exporter \
    --namespace "$NAMESPACE" \
    --version "$DCGM_CHART_VERSION" \
    -f "${SCRIPT_DIR}/dcgm-exporter/values.yaml" \
    --wait \
    --timeout 5m \
    $DRY_RUN
fi

# ---- Step 3: Grafana Dashboards ----
if [[ "$SKIP_DASHBOARDS" == "false" ]]; then
  echo ""
  echo "--- Step 3/4: Loading Grafana Dashboards ---"

  for dashboard_file in "${SCRIPT_DIR}"/dashboards/*.json; do
    dashboard_name="$(basename "$dashboard_file" .json)"
    echo "  Loading dashboard: $dashboard_name"
    kubectl create configmap "grafana-dashboard-${dashboard_name}" \
      --from-file="${dashboard_name}.json=${dashboard_file}" \
      --namespace "$NAMESPACE" \
      --dry-run=client -o yaml | \
      kubectl label --local -f - grafana_dashboard=1 -o yaml | \
      kubectl apply -f -
  done
  echo "  Dashboards loaded. They will auto-appear in Grafana."
else
  echo ""
  echo "--- Step 3/4: Skipping dashboards (--skip-dashboards) ---"
fi

# ---- Step 4: Prometheus Alerts ----
if [[ "$SKIP_ALERTS" == "false" ]]; then
  echo ""
  echo "--- Step 4/4: Applying PrometheusRules ---"

  for alert_file in "${SCRIPT_DIR}"/alerts/*.yaml; do
    alert_name="$(basename "$alert_file")"
    echo "  Applying alert rules: $alert_name"
    kubectl apply -f "$alert_file" -n "$NAMESPACE"
  done
  echo "  Alert rules applied."
else
  echo ""
  echo "--- Step 4/4: Skipping alerts (--skip-alerts) ---"
fi

echo ""
echo "=== Monitoring Stack Installation Complete ==="
echo ""
echo "Access Grafana:"
echo "  kubectl port-forward svc/kube-prometheus-stack-grafana 3000:3000 -n $NAMESPACE"
echo "  URL:      http://localhost:3000"
echo "  User:     admin"
echo "  Password: (as configured)"
echo ""
echo "Access Prometheus:"
echo "  kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n $NAMESPACE"
echo "  URL: http://localhost:9090"
echo ""
echo "Verify DCGM metrics:"
echo "  kubectl port-forward svc/dcgm-exporter 9400:9400 -n gpu-operator"
echo "  curl http://localhost:9400/metrics | grep DCGM"
