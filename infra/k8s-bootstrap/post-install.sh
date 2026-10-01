#!/usr/bin/env bash
###############################################################################
# Post-Install Script for Kubernetes GPU Cluster
#
# Runs after k3s-install.sh or kubeadm-install.sh to set up:
#   - Helm 3
#   - NVIDIA Helm repositories (GPU Operator, Network Operator)
#   - Prometheus community Helm repository
#   - Standard namespaces for the inference platform
#   - NVIDIA container toolkit verification
#
# Usage:
#   bash post-install.sh
#
# Prerequisites:
#   - Kubernetes cluster running (k3s or kubeadm)
#   - kubectl configured and working
#   - Root or sudo access
###############################################################################
set -euo pipefail

# -- Colors -------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# -- Namespaces to create -----------------------------------------------------
NAMESPACES=(
    "gpu-operator"
    "monitoring"
    "inference"
    "enterprise"
    "gateway"
)

# -- Pre-flight checks -------------------------------------------------------
preflight_checks() {
    log_info "Running pre-flight checks..."

    # Check kubectl is available and connected
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl not found in PATH"
        exit 1
    fi

    if ! kubectl cluster-info &>/dev/null; then
        log_error "kubectl cannot connect to the cluster"
        log_error "Ensure KUBECONFIG is set or the cluster is running"
        exit 1
    fi

    log_info "Cluster connection verified"
    kubectl get nodes -o wide
}

# -- Install Helm 3 -----------------------------------------------------------
install_helm() {
    if command -v helm &>/dev/null; then
        local current_version
        current_version=$(helm version --short 2>/dev/null | head -1)
        log_info "Helm already installed: ${current_version}"
        return 0
    fi

    log_info "Installing Helm 3..."

    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

    # Verify installation
    if ! command -v helm &>/dev/null; then
        log_error "Helm installation failed"
        exit 1
    fi

    log_info "Helm installed: $(helm version --short)"
}

# -- Add Helm repositories ----------------------------------------------------
add_helm_repos() {
    log_info "Adding Helm repositories..."

    # NVIDIA GPU Operator
    helm repo add nvidia https://helm.ngc.nvidia.com/nvidia \
        --force-update 2>/dev/null || true
    log_info "  Added: nvidia (GPU Operator, Network Operator)"

    # Prometheus community
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts \
        --force-update 2>/dev/null || true
    log_info "  Added: prometheus-community"

    # Grafana
    helm repo add grafana https://grafana.github.io/helm-charts \
        --force-update 2>/dev/null || true
    log_info "  Added: grafana"

    # Update all repos
    log_info "Updating Helm repositories..."
    helm repo update

    log_info "Helm repositories configured"
}

# -- Create namespaces --------------------------------------------------------
create_namespaces() {
    log_info "Creating namespaces..."

    for ns in "${NAMESPACES[@]}"; do
        if kubectl get namespace "$ns" &>/dev/null; then
            log_info "  Namespace '${ns}' already exists"
        else
            kubectl create namespace "$ns"
            kubectl label namespace "$ns" \
                app.kubernetes.io/managed-by=post-install \
                platform=llm-inference \
                --overwrite
            log_info "  Created namespace '${ns}'"
        fi
    done

    log_info "All namespaces ready"
}

# -- Install NVIDIA Container Toolkit (if not present) ------------------------
ensure_nvidia_toolkit() {
    if command -v nvidia-container-runtime &>/dev/null; then
        log_info "NVIDIA Container Toolkit already installed"
        return 0
    fi

    log_info "Installing NVIDIA Container Toolkit..."

    # Detect package manager
    if command -v apt-get &>/dev/null; then
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
            | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null

        curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
            | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
            | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

        apt-get update
        apt-get install -y nvidia-container-toolkit
    elif command -v yum &>/dev/null; then
        curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
            | tee /etc/yum.repos.d/nvidia-container-toolkit.repo >/dev/null

        yum install -y nvidia-container-toolkit
    else
        log_warn "Unsupported package manager. Install nvidia-container-toolkit manually."
        return 0
    fi

    log_info "NVIDIA Container Toolkit installed"
}

# -- Verify GPU visibility ----------------------------------------------------
verify_gpu_visibility() {
    log_info "Verifying GPU visibility..."

    if ! command -v nvidia-smi &>/dev/null; then
        log_warn "nvidia-smi not found - GPU verification skipped"
        return 0
    fi

    echo ""
    echo "  GPU Summary:"
    nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv
    echo ""

    local gpu_count
    gpu_count=$(nvidia-smi --query-gpu=count --format=csv,noheader | head -1 | tr -d '[:space:]')

    if [[ "$gpu_count" -ge 1 ]]; then
        log_info "Detected ${gpu_count} GPU(s) - ready for GPU Operator"
    else
        log_warn "No GPUs detected. GPU Operator will still install but pods will be pending."
    fi

    # Check NVIDIA driver version
    local driver_version
    driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | tr -d '[:space:]')
    log_info "NVIDIA driver version: ${driver_version}"
}

# -- Print summary ------------------------------------------------------------
print_summary() {
    echo ""
    echo "============================================================"
    echo " Post-Install Complete"
    echo "============================================================"
    echo ""
    echo "  Helm:       $(helm version --short 2>/dev/null || echo 'N/A')"
    echo "  Repos:      $(helm repo list 2>/dev/null | tail -n +2 | wc -l | tr -d '[:space:]') configured"
    echo "  Namespaces: ${#NAMESPACES[@]} created"
    echo ""
    echo "  Namespaces:"
    for ns in "${NAMESPACES[@]}"; do
        echo "    - ${ns}"
    done
    echo ""
    echo "  Next steps:"
    echo "    1. Install GPU Operator:  make install-gpu-operator"
    echo "    2. Install monitoring:    make install-monitoring"
    echo "    3. Deploy inference:      make deploy-70b-tp4"
    echo ""
    echo "============================================================"
}

# -- Main ---------------------------------------------------------------------
main() {
    echo "============================================================"
    echo " Kubernetes Post-Install Setup"
    echo "============================================================"
    echo ""

    preflight_checks
    install_helm
    add_helm_repos
    create_namespaces
    ensure_nvidia_toolkit
    verify_gpu_visibility
    print_summary
}

main "$@"
