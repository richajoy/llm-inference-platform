#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="gpu-operator"
CHART_VERSION="v24.9.0"
MIG_STRATEGY=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install NVIDIA GPU Operator via Helm.

Options:
  --mig-single    Enable MIG with single strategy
  --mig-mixed     Enable MIG with mixed strategy
  --chart-version Version of GPU Operator chart (default: $CHART_VERSION)
  --dry-run       Render templates without installing
  -h, --help      Show this help message
EOF
}

DRY_RUN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mig-single)
      MIG_STRATEGY="single"
      shift
      ;;
    --mig-mixed)
      MIG_STRATEGY="mixed"
      shift
      ;;
    --chart-version)
      CHART_VERSION="$2"
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

echo "=== Installing NVIDIA GPU Operator ==="
echo "  Namespace:     $NAMESPACE"
echo "  Chart Version: $CHART_VERSION"
echo "  MIG Strategy:  ${MIG_STRATEGY:-disabled}"

# Add NVIDIA Helm repo
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>/dev/null || true
helm repo update nvidia

# Create namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Build values file list
VALUES_FILES=("-f" "${SCRIPT_DIR}/values.yaml")

if [[ "$MIG_STRATEGY" == "single" ]]; then
  VALUES_FILES+=("-f" "${SCRIPT_DIR}/values-mig-single.yaml")
  echo "  MIG profiles will be loaded from: ${SCRIPT_DIR}/mig-profiles/"
elif [[ "$MIG_STRATEGY" == "mixed" ]]; then
  VALUES_FILES+=("-f" "${SCRIPT_DIR}/values-mig-mixed.yaml")
  echo "  MIG profiles will be loaded from: ${SCRIPT_DIR}/mig-profiles/"
fi

# Install or upgrade GPU Operator
helm upgrade --install gpu-operator nvidia/gpu-operator \
  --namespace "$NAMESPACE" \
  --version "$CHART_VERSION" \
  "${VALUES_FILES[@]}" \
  --wait \
  --timeout 10m \
  $DRY_RUN

# If MIG is enabled, create the ConfigMap with MIG profiles
if [[ -n "$MIG_STRATEGY" ]]; then
  echo ""
  echo "=== Creating MIG profile ConfigMap ==="

  # Merge all MIG profile files into a single ConfigMap
  CONFIGMAP_ARGS=("--from-file=config.yaml=${SCRIPT_DIR}/mig-profiles/all-1g-10gb.yaml")

  for profile_file in "${SCRIPT_DIR}"/mig-profiles/*.yaml; do
    profile_name="$(basename "$profile_file")"
    CONFIGMAP_ARGS+=("--from-file=${profile_name}=${profile_file}")
  done

  # Build the merged mig-parted config from all profiles
  MERGED_CONFIG=$(cat "${SCRIPT_DIR}"/mig-profiles/*.yaml | grep -v "^version:" | grep -v "^---" | head -1)

  # Create a merged config file
  MERGED_FILE=$(mktemp)
  trap "rm -f $MERGED_FILE" EXIT
  echo "version: v1" > "$MERGED_FILE"
  echo "mig-configs:" >> "$MERGED_FILE"
  for profile_file in "${SCRIPT_DIR}"/mig-profiles/*.yaml; do
    # Extract the mig-configs content (skip version and mig-configs header)
    sed -n '/^  /p' "$profile_file" >> "$MERGED_FILE"
  done

  kubectl create configmap mig-parted-config \
    --from-file=config.yaml="$MERGED_FILE" \
    --namespace "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo "  MIG profiles loaded. Apply a profile to a node with:"
  echo "    kubectl label node <node> nvidia.com/mig.config=<profile> --overwrite"
  echo "  Available profiles: all-1g-10gb, all-3g-40gb, balanced"
fi

echo ""
echo "=== GPU Operator Installation Complete ==="
echo ""
echo "Verify with:"
echo "  kubectl get pods -n $NAMESPACE"
echo "  kubectl get nodes -o json | jq '.items[].metadata.labels | with_entries(select(.key | startswith(\"nvidia\")))'"
