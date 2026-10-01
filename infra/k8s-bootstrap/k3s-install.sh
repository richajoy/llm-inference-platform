#!/usr/bin/env bash
###############################################################################
# k3s Installation Script for RunPod GPU Pods
#
# Installs k3s v1.31+ with NVIDIA GPU runtime support for running
# LLM inference workloads on RunPod 8xH100 SXM pods.
#
# Usage:
#   bash k3s-install.sh
#
# Prerequisites:
#   - Running on a RunPod GPU pod with NVIDIA drivers installed
#   - Root access
#   - Internet connectivity
###############################################################################
set -euo pipefail

# -- Constants ----------------------------------------------------------------
K3S_VERSION="${K3S_VERSION:-v1.31.4+k3s1}"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
CONTAINERD_CONFIG="/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl"
NVIDIA_RUNTIME_PATH="/usr/bin/nvidia-container-runtime"

# -- Colors for output --------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# -- Pre-flight checks -------------------------------------------------------
preflight_checks() {
    log_info "Running pre-flight checks..."

    # Must be root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi

    # Check NVIDIA driver
    if ! command -v nvidia-smi &>/dev/null; then
        log_error "nvidia-smi not found. NVIDIA drivers must be installed."
        exit 1
    fi

    log_info "GPU status:"
    nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader

    # Check internet connectivity
    if ! curl -sf --max-time 5 https://get.k3s.io >/dev/null 2>&1; then
        log_error "Cannot reach https://get.k3s.io - check internet connectivity"
        exit 1
    fi

    log_info "Pre-flight checks passed"
}

# -- Install NVIDIA Container Toolkit ----------------------------------------
install_nvidia_container_toolkit() {
    if command -v nvidia-container-runtime &>/dev/null; then
        log_info "NVIDIA Container Toolkit already installed"
        return 0
    fi

    log_info "Installing NVIDIA Container Toolkit..."

    # Add NVIDIA container toolkit repository
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

    apt-get update
    apt-get install -y nvidia-container-toolkit nvidia-container-runtime

    log_info "NVIDIA Container Toolkit installed"
}

# -- Configure containerd for NVIDIA runtime ----------------------------------
configure_containerd_nvidia() {
    log_info "Configuring containerd for NVIDIA runtime..."

    # Create the containerd config template directory
    mkdir -p "$(dirname "$CONTAINERD_CONFIG")"

    cat > "$CONTAINERD_CONFIG" <<'TOML'
[plugins."io.containerd.grpc.v1.cri".containerd]
  default_runtime_name = "nvidia"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
  privileged_without_host_devices = false
  runtime_engine = ""
  runtime_root = ""
  runtime_type = "io.containerd.runc.v2"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
  BinaryName = "/usr/bin/nvidia-container-runtime"
  SystemdCgroup = true
TOML

    log_info "containerd NVIDIA runtime configured"
}

# -- Install k3s --------------------------------------------------------------
install_k3s() {
    log_info "Installing k3s ${K3S_VERSION}..."

    # Configure containerd before k3s installation
    configure_containerd_nvidia

    # Install k3s with GPU-specific flags
    curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="${K3S_VERSION}" \
        INSTALL_K3S_EXEC="server" \
        sh -s - \
            --disable=traefik \
            --disable=servicelb \
            --kubelet-arg="feature-gates=DevicePlugins=true" \
            --kubelet-arg="max-pods=110" \
            --kube-apiserver-arg="feature-gates=DevicePlugins=true" \
            --write-kubeconfig-mode=644

    log_info "k3s installed"
}

# -- Wait for node to be ready -----------------------------------------------
wait_for_ready() {
    log_info "Waiting for k3s node to become Ready..."

    local retries=60
    local count=0

    while [[ $count -lt $retries ]]; do
        if kubectl get nodes 2>/dev/null | grep -q " Ready"; then
            log_info "Node is Ready"
            kubectl get nodes -o wide
            return 0
        fi
        count=$((count + 1))
        echo -n "."
        sleep 5
    done

    log_error "Timed out waiting for node to become Ready (${retries} attempts)"
    kubectl get nodes -o wide 2>/dev/null || true
    journalctl -u k3s --no-pager --lines=50
    exit 1
}

# -- Export kubeconfig --------------------------------------------------------
export_kubeconfig() {
    log_info "Setting up kubeconfig..."

    # Set KUBECONFIG for current shell
    export KUBECONFIG="$KUBECONFIG_PATH"

    # Add to shell profile for persistence
    local profile_file="/root/.bashrc"
    if ! grep -q "KUBECONFIG" "$profile_file" 2>/dev/null; then
        echo "export KUBECONFIG=${KUBECONFIG_PATH}" >> "$profile_file"
    fi

    # Also set up for workspace if mounted
    if [[ -d /workspace ]]; then
        cp "$KUBECONFIG_PATH" /workspace/kubeconfig.yaml
        chmod 600 /workspace/kubeconfig.yaml
        log_info "Kubeconfig copied to /workspace/kubeconfig.yaml"
    fi

    log_info "KUBECONFIG set to ${KUBECONFIG_PATH}"
}

# -- Verify GPU visibility in k3s --------------------------------------------
verify_gpu() {
    log_info "Verifying GPU visibility..."

    # Quick nvidia-smi check
    nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv,noheader

    local gpu_count
    gpu_count=$(nvidia-smi --query-gpu=count --format=csv,noheader | head -1 | tr -d '[:space:]')
    log_info "Detected ${gpu_count} GPU(s)"

    if [[ "$gpu_count" -lt 1 ]]; then
        log_error "No GPUs detected by nvidia-smi"
        exit 1
    fi
}

# -- Main ---------------------------------------------------------------------
main() {
    echo "============================================================"
    echo " k3s Installation for RunPod GPU Pod"
    echo " k3s version: ${K3S_VERSION}"
    echo "============================================================"
    echo ""

    preflight_checks
    install_nvidia_container_toolkit
    install_k3s
    wait_for_ready
    export_kubeconfig
    verify_gpu

    echo ""
    echo "============================================================"
    log_info "k3s installation complete"
    echo ""
    echo "  KUBECONFIG: ${KUBECONFIG_PATH}"
    echo "  Node count: $(kubectl get nodes --no-headers | wc -l)"
    echo "  GPUs:       $(nvidia-smi --query-gpu=count --format=csv,noheader | head -1)"
    echo ""
    echo "  Next: Run post-install.sh to install Helm + NVIDIA Operator"
    echo "============================================================"
}

main "$@"
