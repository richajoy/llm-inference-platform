#!/usr/bin/env bash
###############################################################################
# End-to-End GKE Setup Script
#
# Orchestrates the full GKE cluster deployment:
#   1. Terraform apply to create GKE cluster + GPU node pool
#   2. Get kubeconfig via gcloud
#   3. Run post-install.sh for Helm + namespaces
#   4. Print success message with endpoints
#
# Usage:
#   bash setup-gke.sh
#
# Prerequisites:
#   - Terraform >= 1.5.0 installed
#   - gcloud CLI installed and authenticated
#   - GCP project with billing and GKE API enabled
###############################################################################
set -euo pipefail

# -- Constants ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TERRAFORM_DIR="${INFRA_DIR}/terraform/gke"
BOOTSTRAP_DIR="${INFRA_DIR}/k8s-bootstrap"

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
    log_info "  Terraform: $(terraform version | head -1)"

    # Check gcloud
    if ! command -v gcloud &>/dev/null; then
        log_error "gcloud CLI not found. Install from https://cloud.google.com/sdk/install"
        exit 1
    fi
    log_info "  gcloud: $(gcloud version 2>/dev/null | head -1)"

    # Check gcloud auth
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 | grep -q "@"; then
        log_error "No active gcloud authentication. Run: gcloud auth login"
        exit 1
    fi
    log_info "  Auth: $(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)"

    # Check kubectl
    if ! command -v kubectl &>/dev/null; then
        log_warn "kubectl not found. Installing via gcloud..."
        gcloud components install kubectl 2>/dev/null || \
            log_warn "Could not install kubectl via gcloud. Install manually."
    fi

    # Check terraform.tfvars
    if [[ ! -f "${TERRAFORM_DIR}/terraform.tfvars" ]] && [[ -z "${TF_VAR_project_id:-}" ]]; then
        log_error "No terraform.tfvars found and TF_VAR_project_id not set"
        log_error "Create ${TERRAFORM_DIR}/terraform.tfvars with at minimum:"
        log_error '  project_id = "your-gcp-project-id"'
        exit 1
    fi

    log_info "Pre-flight checks passed"
}

# -- Step 1: Terraform init and apply ----------------------------------------
terraform_apply() {
    log_step "Step 1/4: Provisioning GKE cluster..."

    cd "$TERRAFORM_DIR"

    # Initialize Terraform
    log_info "Running terraform init..."
    terraform init -input=false

    # Validate
    log_info "Validating Terraform configuration..."
    terraform validate

    # Plan
    log_info "Planning infrastructure changes..."
    terraform plan -out=tfplan

    # Apply
    log_info "Applying Terraform plan (this may take 10-15 minutes)..."
    terraform apply -input=false tfplan

    # Clean up plan file
    rm -f tfplan

    log_info "Terraform apply complete"
}

# -- Step 2: Get kubeconfig ---------------------------------------------------
get_kubeconfig() {
    log_step "Step 2/4: Configuring kubectl..."

    cd "$TERRAFORM_DIR"

    # Get the kubeconfig command from Terraform output
    local kubeconfig_cmd
    kubeconfig_cmd=$(terraform output -raw kubeconfig_command 2>/dev/null)

    if [[ -z "$kubeconfig_cmd" ]]; then
        log_error "Could not get kubeconfig command from Terraform output"
        exit 1
    fi

    log_info "Running: ${kubeconfig_cmd}"
    eval "$kubeconfig_cmd"

    # Verify connection
    log_info "Verifying cluster connection..."
    if ! kubectl cluster-info &>/dev/null; then
        log_error "kubectl cannot connect to the GKE cluster"
        exit 1
    fi

    kubectl get nodes -o wide
    log_info "Kubeconfig configured"
}

# -- Step 3: Run post-install -------------------------------------------------
run_post_install() {
    log_step "Step 3/4: Running post-install setup..."

    bash "${BOOTSTRAP_DIR}/post-install.sh"

    log_info "Post-install complete"
}

# -- Step 4: Print success message --------------------------------------------
print_success() {
    log_step "Step 4/4: Setup complete!"

    cd "$TERRAFORM_DIR"

    local cluster_name
    local cluster_location
    local gpu_pool
    cluster_name=$(terraform output -raw cluster_name 2>/dev/null || echo "llm-inference")
    cluster_location=$(terraform output -raw cluster_location 2>/dev/null || echo "us-central1-c")
    gpu_pool=$(terraform output -raw gpu_nodepool_name 2>/dev/null || echo "gpu-h100-pool")

    echo ""
    echo "============================================================"
    echo " GKE Cluster Ready"
    echo "============================================================"
    echo ""
    echo "  Cluster:      ${cluster_name}"
    echo "  Location:     ${cluster_location}"
    echo "  GPU Pool:     ${gpu_pool}"
    echo ""
    echo "  Verify:"
    echo "    kubectl get nodes -o wide"
    echo "    kubectl get ns"
    echo ""
    echo "  Next steps:"
    echo "    make install-platform    # GPU Operator + Monitoring + Gateway"
    echo "    make deploy-70b-tp4      # Deploy Llama 70B with tensor parallelism"
    echo ""
    echo "============================================================"
}

# -- Main ---------------------------------------------------------------------
main() {
    echo "============================================================"
    echo " GKE End-to-End Setup"
    echo " Target: A3 Ultra (8x H100 SXM) Node Pool"
    echo "============================================================"
    echo ""

    preflight_checks
    terraform_apply
    get_kubeconfig
    run_post_install
    print_success
}

main "$@"
