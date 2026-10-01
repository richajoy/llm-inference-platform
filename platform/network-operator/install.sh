#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="gpu-operator"
CHART_VERSION="v24.7.0"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install NVIDIA Network Operator for InfiniBand/RDMA networking.

NOTE: Skip this on RunPod (InfiniBand is pre-configured).
      Required on bare-metal, GKE, and EKS clusters with InfiniBand.

Options:
  --chart-version  Version of Network Operator chart (default: $CHART_VERSION)
  --skip-sriov     Skip SR-IOV policy creation
  --dry-run        Render templates without installing
  -h, --help       Show this help message
EOF
}

DRY_RUN=""
SKIP_SRIOV=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --chart-version)
      CHART_VERSION="$2"
      shift 2
      ;;
    --skip-sriov)
      SKIP_SRIOV=true
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

# Detect if running on RunPod (InfiniBand is pre-configured)
if kubectl get nodes -o jsonpath='{.items[0].metadata.labels}' 2>/dev/null | grep -q "runpod.io"; then
  echo "=== RunPod detected: Skipping Network Operator installation ==="
  echo "  InfiniBand/RDMA is pre-configured on RunPod nodes."
  echo "  NCCL will use InfiniBand automatically via NCCL_IB_DISABLE=0."
  exit 0
fi

echo "=== Installing NVIDIA Network Operator ==="
echo "  Namespace:     $NAMESPACE"
echo "  Chart Version: $CHART_VERSION"

# Add NVIDIA Helm repo
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>/dev/null || true
helm repo update nvidia

# Create namespace (shared with GPU Operator)
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Install Network Operator
helm upgrade --install network-operator nvidia/network-operator \
  --namespace "$NAMESPACE" \
  --version "$CHART_VERSION" \
  -f "${SCRIPT_DIR}/values.yaml" \
  --wait \
  --timeout 10m \
  $DRY_RUN

echo ""
echo "=== Applying NicClusterPolicy ==="
kubectl apply -f "${SCRIPT_DIR}/nic-cluster-policy.yaml"

# Create inference namespace for NetworkAttachmentDefinition
kubectl create namespace inference --dry-run=client -o yaml | kubectl apply -f -

if [[ "$SKIP_SRIOV" == "false" ]]; then
  echo ""
  echo "=== Applying SR-IOV Policy ==="
  kubectl apply -f "${SCRIPT_DIR}/sriov-policy.yaml"
  echo "  SR-IOV VFs will be created after node reboot (if required)."
fi

echo ""
echo "=== Network Operator Installation Complete ==="
echo ""
echo "Verify with:"
echo "  kubectl get pods -n $NAMESPACE -l app=network-operator"
echo "  kubectl get nicclusterpolicies"
echo "  kubectl get sriovnetworknodepolicies -n $NAMESPACE"
echo "  kubectl get node-resource -o wide  # Check RDMA resources"
