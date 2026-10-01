#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# KubeRay Operator Installation
#
# Installs the KubeRay operator for managing Ray clusters on Kubernetes.
# Required for production multi-node vLLM deployments (TP/PP across nodes).
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${KUBERAY_NAMESPACE:-kuberay-system}"
RELEASE_NAME="kuberay-operator"
CHART_VERSION="1.3.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[KubeRay]${NC} $*"; }
warn() { echo -e "${YELLOW}[KubeRay]${NC} $*"; }
err()  { echo -e "${RED}[KubeRay]${NC} $*" >&2; }

# Pre-flight checks
command -v helm >/dev/null 2>&1 || { err "helm not found. Run post-install.sh first."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { err "kubectl not found."; exit 1; }

# Add KubeRay Helm repo
log "Adding KubeRay Helm repository..."
helm repo add kuberay https://ray-project.github.io/kuberay-helm/ 2>/dev/null || true
helm repo update kuberay

# Create namespace
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Install KubeRay operator
log "Installing KubeRay operator v${CHART_VERSION}..."
helm upgrade --install "${RELEASE_NAME}" kuberay/kuberay-operator \
  --namespace "${NAMESPACE}" \
  --version "${CHART_VERSION}" \
  --values "${SCRIPT_DIR}/values.yaml" \
  --wait \
  --timeout 5m

# Verify installation
log "Verifying KubeRay operator..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=kuberay-operator \
  -n "${NAMESPACE}" \
  --timeout=120s

# Verify CRDs
log "Checking CRDs..."
for crd in rayclusters.ray.io rayjobs.ray.io rayservices.ray.io; do
  if kubectl get crd "${crd}" &>/dev/null; then
    log "  CRD ${crd} installed"
  else
    err "  CRD ${crd} NOT found"
    exit 1
  fi
done

log "KubeRay operator installed successfully!"
log ""
log "Next steps:"
log "  1. Deploy a RayCluster:  kubectl apply -f inference/ray-cluster/"
log "  2. Deploy vLLM on Ray:   make deploy-405b-ray"
log "  3. Check Ray dashboard:  kubectl port-forward svc/raycluster-head-svc 8265:8265 -n inference"
