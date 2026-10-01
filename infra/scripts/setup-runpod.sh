#!/usr/bin/env bash
###############################################################################
# End-to-End RunPod Setup Script
#
# Orchestrates the full RunPod infrastructure deployment:
#   1. Terraform apply to provision 8xH100 SXM pod
#   2. Wait for pod to become ready
#   3. SSH into pod and run k3s-install.sh
#   4. Run post-install.sh for Helm + namespaces
#   5. Print success message with endpoints
#
# Usage:
#   bash setup-runpod.sh
#
# Prerequisites:
#   - Terraform >= 1.5.0 installed
#   - RunPod API key in terraform.tfvars or TF_VAR_runpod_api_key
#   - SSH key configured for RunPod access
###############################################################################
set -euo pipefail

# -- Constants ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TERRAFORM_DIR="${INFRA_DIR}/terraform/runpod"
BOOTSTRAP_DIR="${INFRA_DIR}/k8s-bootstrap"

# SSH settings
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_runpod}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

# Timeouts
POD_READY_TIMEOUT=300  # 5 minutes
SSH_READY_TIMEOUT=120  # 2 minutes

# -- Colors -------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }

# -- Pre-flight checks -------------------------------------------------------
preflight_checks() {
    log_info "Running pre-flight checks..."

    # Check Terraform
    if ! command -v terraform &>/dev/null; then
        log_error "Terraform not found. Install from https://www.terraform.io/downloads"
        exit 1
    fi
    log_info "  Terraform: $(terraform version -json | python3 -c 'import sys,json; print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || terraform version | head -1)"

    # Check terraform.tfvars or env var
    if [[ ! -f "${TERRAFORM_DIR}/terraform.tfvars" ]] && [[ -z "${TF_VAR_runpod_api_key:-}" ]]; then
        log_error "No terraform.tfvars found and TF_VAR_runpod_api_key not set"
        log_error "Copy terraform.tfvars.example to terraform.tfvars and set your API key:"
        log_error "  cp ${TERRAFORM_DIR}/terraform.tfvars.example ${TERRAFORM_DIR}/terraform.tfvars"
        exit 1
    fi

    # Check SSH key
    if [[ ! -f "$SSH_KEY" ]]; then
        log_warn "SSH key not found at ${SSH_KEY}"
        log_warn "You can set SSH_KEY env var or create a key with: ssh-keygen -t ed25519 -f ${SSH_KEY}"
    fi

    log_info "Pre-flight checks passed"
}

# -- Step 1: Terraform init and apply ----------------------------------------
terraform_apply() {
    log_step "Step 1/5: Provisioning RunPod infrastructure..."

    cd "$TERRAFORM_DIR"

    # Initialize Terraform
    log_info "Running terraform init..."
    terraform init -input=false

    # Validate configuration
    log_info "Validating Terraform configuration..."
    terraform validate

    # Plan
    log_info "Planning infrastructure changes..."
    terraform plan -out=tfplan

    # Apply
    log_info "Applying Terraform plan..."
    terraform apply -input=false tfplan

    # Clean up plan file
    rm -f tfplan

    log_info "Terraform apply complete"
}

# -- Step 2: Wait for pod to be ready ----------------------------------------
wait_for_pod() {
    log_step "Step 2/5: Waiting for RunPod pod to become ready..."

    cd "$TERRAFORM_DIR"

    local pod_ip
    pod_ip=$(terraform output -json pod_ips 2>/dev/null | python3 -c 'import sys,json; ips=json.load(sys.stdin); print(ips[0] if ips else "")' 2>/dev/null || echo "")

    if [[ -z "$pod_ip" ]]; then
        log_warn "Could not extract pod IP from Terraform output"
        log_info "Waiting ${POD_READY_TIMEOUT}s for pod initialization..."
        sleep 30
        pod_ip=$(terraform output -json pod_ips 2>/dev/null | python3 -c 'import sys,json; ips=json.load(sys.stdin); print(ips[0] if ips else "")' 2>/dev/null || echo "")
    fi

    if [[ -z "$pod_ip" ]]; then
        log_error "Failed to get pod IP. Check RunPod console manually."
        terraform output
        exit 1
    fi

    log_info "Pod IP: ${pod_ip}"

    # Wait for SSH to become available
    log_info "Waiting for SSH connectivity..."
    local retries=$((SSH_READY_TIMEOUT / 5))
    local count=0

    while [[ $count -lt $retries ]]; do
        if ssh ${SSH_OPTS} -i "$SSH_KEY" "root@${pod_ip}" "echo 'SSH ready'" 2>/dev/null; then
            log_info "SSH connection established"
            echo "$pod_ip" > /tmp/runpod_ip
            return 0
        fi
        count=$((count + 1))
        echo -n "."
        sleep 5
    done

    log_error "SSH connection timed out after ${SSH_READY_TIMEOUT}s"
    log_error "Pod IP: ${pod_ip}"
    log_error "Try manually: ssh ${SSH_OPTS} -i ${SSH_KEY} root@${pod_ip}"
    exit 1
}

# -- Step 3: Install k3s on the pod ------------------------------------------
install_k3s() {
    log_step "Step 3/5: Installing k3s on RunPod pod..."

    local pod_ip
    pod_ip=$(cat /tmp/runpod_ip)

    # Copy bootstrap scripts to the pod
    log_info "Copying bootstrap scripts to pod..."
    scp ${SSH_OPTS} -i "$SSH_KEY" \
        "${BOOTSTRAP_DIR}/k3s-install.sh" \
        "${BOOTSTRAP_DIR}/post-install.sh" \
        "root@${pod_ip}:/workspace/"

    # Run k3s installation
    log_info "Running k3s-install.sh on pod..."
    ssh ${SSH_OPTS} -i "$SSH_KEY" "root@${pod_ip}" \
        "chmod +x /workspace/k3s-install.sh && bash /workspace/k3s-install.sh"

    log_info "k3s installed successfully"
}

# -- Step 4: Run post-install -------------------------------------------------
run_post_install() {
    log_step "Step 4/5: Running post-install setup..."

    local pod_ip
    pod_ip=$(cat /tmp/runpod_ip)

    ssh ${SSH_OPTS} -i "$SSH_KEY" "root@${pod_ip}" \
        "chmod +x /workspace/post-install.sh && bash /workspace/post-install.sh"

    log_info "Post-install complete"
}

# -- Step 5: Print success message --------------------------------------------
print_success() {
    log_step "Step 5/5: Setup complete!"

    local pod_ip
    pod_ip=$(cat /tmp/runpod_ip)

    cd "$TERRAFORM_DIR"

    echo ""
    echo "============================================================"
    echo " RunPod Infrastructure Ready"
    echo "============================================================"
    echo ""
    echo "  Pod IP:       ${pod_ip}"
    echo "  SSH:          ssh -i ${SSH_KEY} root@${pod_ip}"
    echo "  K3s API:      https://${pod_ip}:6443"
    echo "  Inference:    http://${pod_ip}:8000"
    echo ""
    echo "  Kubeconfig (from pod):"
    echo "    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
    echo ""
    echo "  Kubeconfig (remote access):"
    echo "    scp -i ${SSH_KEY} root@${pod_ip}:/etc/rancher/k3s/k3s.yaml ./kubeconfig.yaml"
    echo "    sed -i 's/127.0.0.1/${pod_ip}/' ./kubeconfig.yaml"
    echo "    export KUBECONFIG=\$(pwd)/kubeconfig.yaml"
    echo ""
    echo "  Next steps:"
    echo "    make install-platform    # GPU Operator + Monitoring + Gateway"
    echo "    make deploy-70b-tp4      # Deploy Llama 70B with tensor parallelism"
    echo ""
    echo "============================================================"

    # Clean up temp file
    rm -f /tmp/runpod_ip
}

# -- Main ---------------------------------------------------------------------
main() {
    echo "============================================================"
    echo " RunPod End-to-End Setup"
    echo " Target: 8x NVIDIA H100 SXM + k3s"
    echo "============================================================"
    echo ""

    preflight_checks
    terraform_apply
    wait_for_pod
    install_k3s
    run_post_install
    print_success
}

main "$@"
