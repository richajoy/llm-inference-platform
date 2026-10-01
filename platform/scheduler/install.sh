#!/usr/bin/env bash
# Install NVIDIA KAI Scheduler (the open-source core of NVIDIA Run:ai).
#
# KAI adds to the stock kube-scheduler:
#   - hierarchical scheduling queues with GPU quota / over-quota weight / limit
#   - fractional GPU requests via pod annotations (gpu-fraction, gpu-memory)
#   - priority classes with preemption (train < build-preemptible < build < inference)
#   - gang scheduling (PodGroups) for TP/PP multi-pod workloads
#
# Docs: https://github.com/NVIDIA/KAI-Scheduler
set -euo pipefail

KAI_VERSION="${KAI_VERSION:-v0.18.2}"
NAMESPACE="kai-scheduler"
# NonMemoryEnforced: schedule fractions, no CUDA memory isolation (default).
# HamiCore:          enforce memory limits with HAMi-core (also install kai-resource-isolator).
# NvFractions:       NVIDIA gpu-fractioning with CDI/NRI runtime enforcement.
GPU_SHARING_MODE="${GPU_SHARING_MODE:-NonMemoryEnforced}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<USAGE
Usage: $0 [--version vX.Y.Z] [--gpu-sharing-mode NonMemoryEnforced|HamiCore|NvFractions]

Prerequisites: NVIDIA GPU Operator installed (platform/gpu-operator).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) KAI_VERSION="$2"; shift 2 ;;
    --gpu-sharing-mode) GPU_SHARING_MODE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

echo "=== Installing KAI Scheduler ${KAI_VERSION} (gpuSharingMode=${GPU_SHARING_MODE}) ==="

extra_args=()
if [[ "$GPU_SHARING_MODE" == "NvFractions" ]]; then
  # Pulls the gpu-sharing subchart from oci://ghcr.io/kai-scheduler/gpu-sharing
  extra_args+=(--set global.nvFractions.set=true)
else
  extra_args+=(--set "global.gpuSharingMode=${GPU_SHARING_MODE}")
fi

helm upgrade -i kai-scheduler oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler \
  -n "$NAMESPACE" --create-namespace \
  --version "$KAI_VERSION" \
  "${extra_args[@]}"

echo "--- Waiting for scheduler pods ---"
kubectl -n "$NAMESPACE" rollout status deploy --timeout=300s 2>/dev/null || true
kubectl -n "$NAMESPACE" get pods

echo "--- Applying scheduling queues ---"
kubectl apply -f "${SCRIPT_DIR}/queues.yaml"
kubectl get queues.scheduling.run.ai

if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  echo "--- Applying ServiceMonitors (Prometheus Operator detected) ---"
  kubectl apply -f "${SCRIPT_DIR}/servicemonitors.yaml"
fi

cat <<DONE

KAI Scheduler installed.

Submit a workload to KAI by setting, on the pod template:
  metadata.labels.kai.scheduler/queue: <leaf queue>
  spec.schedulerName: kai-scheduler
Fractional GPU: metadata.annotations.gpu-fraction: "0.5" (or gpu-memory: "<MiB>")

Examples:
  kubectl apply -f ${SCRIPT_DIR}/vllm-fractional-gpu.yaml
  kubectl apply -f ${SCRIPT_DIR}/batch-eval-preemptible.yaml
DONE
