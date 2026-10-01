#!/usr/bin/env bash
###############################################################################
# kubeadm Multi-Node Kubernetes Bootstrap Script
#
# Installs a production-grade Kubernetes cluster using kubeadm with:
#   - containerd + NVIDIA container runtime
#   - Calico CNI for pod networking
#   - Control plane init + worker join workflow
#
# Usage:
#   # On control plane node:
#   bash kubeadm-install.sh init
#
#   # On worker nodes (after init outputs the join command):
#   bash kubeadm-install.sh join --token <token> --discovery-token-ca-cert-hash <hash> --control-plane-endpoint <ip:port>
#
# Prerequisites:
#   - Ubuntu 22.04+ with NVIDIA drivers installed
#   - Root access
#   - Unique hostname per node
###############################################################################
set -euo pipefail

# -- Constants ----------------------------------------------------------------
KUBE_VERSION="${KUBE_VERSION:-1.31}"
CALICO_VERSION="${CALICO_VERSION:-v3.28.0}"
POD_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"
CONTAINERD_CONFIG="/etc/containerd/config.toml"

# -- Colors -------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# -- Pre-flight checks -------------------------------------------------------
preflight_checks() {
    log_info "Running pre-flight checks..."

    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi

    # Check OS
    if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        log_warn "This script is designed for Ubuntu. Other distros may require adjustments."
    fi

    # Check NVIDIA drivers
    if ! command -v nvidia-smi &>/dev/null; then
        log_error "nvidia-smi not found. Install NVIDIA drivers first."
        exit 1
    fi

    log_info "GPU status:"
    nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader

    log_info "Pre-flight checks passed"
}

# -- Disable swap (required for kubelet) --------------------------------------
disable_swap() {
    log_info "Disabling swap..."
    swapoff -a || true
    sed -i '/\sswap\s/d' /etc/fstab
    log_info "Swap disabled"
}

# -- Load kernel modules ------------------------------------------------------
configure_kernel() {
    log_info "Configuring kernel modules and sysctl..."

    cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

    modprobe overlay
    modprobe br_netfilter

    cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

    sysctl --system >/dev/null 2>&1
    log_info "Kernel configured"
}

# -- Install containerd with NVIDIA runtime -----------------------------------
install_containerd() {
    log_info "Installing containerd..."

    apt-get update
    apt-get install -y containerd

    # Generate default config
    mkdir -p /etc/containerd
    containerd config default > "$CONTAINERD_CONFIG"

    # Enable SystemdCgroup
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "$CONTAINERD_CONFIG"

    log_info "Installing NVIDIA Container Toolkit..."

    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

    apt-get update
    apt-get install -y nvidia-container-toolkit

    # Configure containerd to use NVIDIA runtime as default
    nvidia-ctk runtime configure --runtime=containerd --set-as-default

    systemctl restart containerd
    systemctl enable containerd

    log_info "containerd installed with NVIDIA runtime"
}

# -- Install kubeadm, kubelet, kubectl ----------------------------------------
install_kube_tools() {
    log_info "Installing kubeadm, kubelet, kubectl v${KUBE_VERSION}..."

    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl gpg

    # Add Kubernetes apt repository
    local keyring="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/Release.key" \
        | gpg --dearmor -o "$keyring"

    echo "deb [signed-by=${keyring}] https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/ /" \
        | tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

    apt-get update
    apt-get install -y kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl

    systemctl enable kubelet

    log_info "Kubernetes tools installed"
    kubeadm version
}

# -- Initialize control plane -------------------------------------------------
init_control_plane() {
    log_info "Initializing Kubernetes control plane..."

    kubeadm init \
        --pod-network-cidr="$POD_CIDR" \
        --service-cidr="$SERVICE_CIDR" \
        --kubernetes-version="v${KUBE_VERSION}.0" \
        --upload-certs \
        --cri-socket="unix:///run/containerd/containerd.sock" \
        | tee /tmp/kubeadm-init.log

    # Set up kubeconfig for root
    export KUBECONFIG=/etc/kubernetes/admin.conf
    mkdir -p /root/.kube
    cp /etc/kubernetes/admin.conf /root/.kube/config
    chmod 600 /root/.kube/config

    # Add to bashrc
    if ! grep -q "KUBECONFIG" /root/.bashrc 2>/dev/null; then
        echo "export KUBECONFIG=/etc/kubernetes/admin.conf" >> /root/.bashrc
    fi

    log_info "Control plane initialized"
}

# -- Install Calico CNI -------------------------------------------------------
install_calico() {
    log_info "Installing Calico CNI ${CALICO_VERSION}..."

    kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"

    cat <<EOF | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: ${POD_CIDR}
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
EOF

    # Wait for Calico to be ready
    log_info "Waiting for Calico pods..."
    local retries=60
    local count=0
    while [[ $count -lt $retries ]]; do
        if kubectl get pods -n calico-system 2>/dev/null | grep -q "Running"; then
            break
        fi
        count=$((count + 1))
        sleep 5
    done

    log_info "Calico CNI installed"
}

# -- Wait for node ready ------------------------------------------------------
wait_for_ready() {
    log_info "Waiting for node to become Ready..."

    local retries=60
    local count=0
    while [[ $count -lt $retries ]]; do
        if kubectl get nodes 2>/dev/null | grep -q " Ready"; then
            log_info "Node is Ready"
            kubectl get nodes -o wide
            return 0
        fi
        count=$((count + 1))
        sleep 5
    done

    log_error "Timed out waiting for node Ready"
    kubectl get nodes -o wide 2>/dev/null || true
    exit 1
}

# -- Join worker node ---------------------------------------------------------
join_worker() {
    log_info "Joining cluster as worker node..."

    if [[ -z "${JOIN_TOKEN:-}" || -z "${CA_CERT_HASH:-}" || -z "${CONTROL_PLANE_ENDPOINT:-}" ]]; then
        log_error "Missing join parameters. Required environment variables:"
        log_error "  JOIN_TOKEN, CA_CERT_HASH, CONTROL_PLANE_ENDPOINT"
        log_error ""
        log_error "Get these from the control plane node's kubeadm init output, or run:"
        log_error "  kubeadm token create --print-join-command"
        exit 1
    fi

    kubeadm join "$CONTROL_PLANE_ENDPOINT" \
        --token "$JOIN_TOKEN" \
        --discovery-token-ca-cert-hash "$CA_CERT_HASH" \
        --cri-socket="unix:///run/containerd/containerd.sock"

    log_info "Worker node joined the cluster"
}

# -- Print join command -------------------------------------------------------
print_join_command() {
    echo ""
    echo "============================================================"
    echo " Worker Node Join Command"
    echo "============================================================"
    echo ""
    echo "Run this on each worker node:"
    echo ""
    grep -A 2 "kubeadm join" /tmp/kubeadm-init.log 2>/dev/null || \
        kubeadm token create --print-join-command
    echo ""
    echo "============================================================"
}

# -- Main ---------------------------------------------------------------------
usage() {
    echo "Usage: $0 {init|join}"
    echo ""
    echo "  init  - Initialize control plane node"
    echo "  join  - Join as worker node (set JOIN_TOKEN, CA_CERT_HASH, CONTROL_PLANE_ENDPOINT)"
    exit 1
}

main() {
    local action="${1:-}"

    if [[ -z "$action" ]]; then
        usage
    fi

    echo "============================================================"
    echo " kubeadm Kubernetes Bootstrap"
    echo " Kubernetes: v${KUBE_VERSION}"
    echo " CNI:        Calico ${CALICO_VERSION}"
    echo " Action:     ${action}"
    echo "============================================================"
    echo ""

    preflight_checks
    disable_swap
    configure_kernel
    install_containerd
    install_kube_tools

    case "$action" in
        init)
            init_control_plane
            install_calico
            wait_for_ready
            print_join_command
            ;;
        join)
            join_worker
            ;;
        *)
            usage
            ;;
    esac

    echo ""
    log_info "kubeadm bootstrap complete (action: ${action})"
}

main "$@"
