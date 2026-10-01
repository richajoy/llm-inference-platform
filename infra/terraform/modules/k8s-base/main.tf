###############################################################################
# Shared Kubernetes Base Module
#
# Creates standard namespaces and common resources used across both
# single-node k3s/kubeadm and GKE deployment targets.
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
  }
}

# -----------------------------------------------------------------------------
# Namespaces
# -----------------------------------------------------------------------------
resource "kubernetes_namespace" "namespaces" {
  for_each = toset(var.namespaces)

  metadata {
    name = each.value

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "platform"                     = "llm-inference"
    }
  }
}

# -----------------------------------------------------------------------------
# ResourceQuota for inference namespace (prevent runaway GPU allocation)
# -----------------------------------------------------------------------------
resource "kubernetes_resource_quota" "inference_quota" {
  count = contains(var.namespaces, "inference") ? 1 : 0

  metadata {
    name      = "inference-gpu-quota"
    namespace = "inference"
  }

  spec {
    hard = {
      "requests.nvidia.com/gpu" = var.max_inference_gpus
      "limits.nvidia.com/gpu"   = var.max_inference_gpus
    }
  }

  depends_on = [kubernetes_namespace.namespaces]
}

# -----------------------------------------------------------------------------
# LimitRange for inference namespace (default resource requests)
# -----------------------------------------------------------------------------
resource "kubernetes_limit_range" "inference_limits" {
  count = contains(var.namespaces, "inference") ? 1 : 0

  metadata {
    name      = "inference-defaults"
    namespace = "inference"
  }

  spec {
    limit {
      type = "Container"
      default_request = {
        cpu    = "1"
        memory = "4Gi"
      }
      default = {
        cpu    = "4"
        memory = "16Gi"
      }
    }
  }

  depends_on = [kubernetes_namespace.namespaces]
}
