#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# KEDA (Kubernetes Event-Driven Autoscaler) Installation
#
# Installs KEDA operator for event-driven autoscaling of vLLM inference pods.
# KEDA extends Kubernetes HPA with Prometheus triggers, cron schedules,
# scale-to-zero, and fallback behavior — purpose-built for LLM workloads.
#
# KEDA vs vanilla HPA for LLM inference:
#   - HPA: Limited to CPU/memory or custom metrics API (needs adapter)
#   - KEDA: Direct Prometheus queries, cron triggers, activation thresholds,
#           scale-to-zero, fallback replicas, multiple trigger composition
#
# Prerequisites:
#   - Helm 3.x installed
#   - kubectl configured with cluster access
#   - Prometheus monitoring deployed: make install-monitoring
###############################################################################

KEDA_VERSION="${KEDA_VERSION:-2.16.1}"
NAMESPACE="${KEDA_NAMESPACE:-keda}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[KEDA]${NC} $*"; }
warn() { echo -e "${YELLOW}[KEDA]${NC} $*"; }
err()  { echo -e "${RED}[KEDA]${NC} $*" >&2; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install KEDA (Kubernetes Event-Driven Autoscaler) operator.

KEDA enables scaling vLLM pods based on Prometheus metrics like
P99 TTFT, ITL/TPOT, KV-cache usage, and request queue depth.

Options:
  --version      KEDA Helm chart version (default: $KEDA_VERSION)
  --namespace    Install namespace (default: $NAMESPACE)
  --dry-run      Render templates without installing
  --with-objects  Also apply ScaledObjects after KEDA install
  -h, --help     Show this help message

Examples:
  $(basename "$0")                    # Standard install
  $(basename "$0") --with-objects     # Install + apply ScaledObjects
  $(basename "$0") --version 2.17.0   # Use specific version
  $(basename "$0") --dry-run          # Preview without installing
EOF
}

DRY_RUN=""
WITH_OBJECTS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      KEDA_VERSION="$2"
      shift 2
      ;;
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="--dry-run"
      shift
      ;;
    --with-objects)
      WITH_OBJECTS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# Pre-flight checks
command -v helm >/dev/null 2>&1 || { err "helm not found. Run post-install.sh first."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { err "kubectl not found."; exit 1; }

log "Installing KEDA v${KEDA_VERSION} into namespace ${NAMESPACE}..."

# Add KEDA Helm repo
log "Adding KEDA Helm repository..."
helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
helm repo update kedacore

# Create namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Install KEDA with production-tuned settings
log "Installing KEDA operator..."
helm upgrade --install keda kedacore/keda \
  --namespace "$NAMESPACE" \
  --version "$KEDA_VERSION" \
  --set resources.operator.requests.cpu=100m \
  --set resources.operator.requests.memory=128Mi \
  --set resources.operator.limits.cpu=1 \
  --set resources.operator.limits.memory=1Gi \
  --set resources.metricServer.requests.cpu=100m \
  --set resources.metricServer.requests.memory=128Mi \
  --set resources.metricServer.limits.cpu=1 \
  --set resources.metricServer.limits.memory=1Gi \
  --set prometheus.metricServer.enabled=true \
  --set prometheus.operator.enabled=true \
  --set prometheus.operator.serviceMonitor.enabled=true \
  --set webhooks.enabled=true \
  --wait \
  --timeout 5m \
  $DRY_RUN

if [[ -n "$DRY_RUN" ]]; then
  log "Dry run complete. No resources created."
  exit 0
fi

# Verify installation
log "Verifying KEDA operator..."
kubectl wait --for=condition=ready pod \
  -l app=keda-operator \
  -n "$NAMESPACE" \
  --timeout=120s

# Verify CRDs
log "Checking CRDs..."
for crd in scaledobjects.keda.sh scaledjobs.keda.sh triggerauthentications.keda.sh clustertriggerauthentications.keda.sh; do
  if kubectl get crd "$crd" &>/dev/null; then
    log "  CRD ${crd} installed"
  else
    err "  CRD ${crd} NOT found"
    exit 1
  fi
done

# Verify metrics server
log "Verifying KEDA metrics server..."
kubectl wait --for=condition=ready pod \
  -l app=keda-operator-metrics-apiserver \
  -n "$NAMESPACE" \
  --timeout=60s

log ""
log "KEDA v${KEDA_VERSION} installed successfully!"

# Optionally apply ScaledObjects
if [[ "$WITH_OBJECTS" == true ]]; then
  log ""
  log "Applying ScaledObjects..."
  kubectl apply -f "${SCRIPT_DIR}/keda-vllm.yaml"
  log "ScaledObject applied. Check with: kubectl get scaledobjects -n inference"
fi

log ""
log "Next steps:"
log "  1. Apply main ScaledObject:  kubectl apply -f platform/autoscaling/keda-vllm.yaml"
log "  2. Apply per-profile:        kubectl apply -f platform/autoscaling/keda-profiles/"
log "  3. Check status:             kubectl get scaledobjects -n inference"
log "  4. Check HPA (KEDA-managed): kubectl get hpa -n inference"
log ""
log "Available scaling patterns:"
log "  keda-vllm.yaml              Main 70B TP=4 (6 SLO triggers)"
log "  keda-profiles/              Per-model ScaledObjects (8B, FP8, P/D)"
log "  keda-cron.yaml              Cron + metric hybrid (business hours)"
log "  keda-scale-to-zero.yaml     Scale-to-zero (dev/staging)"
