###############################################################################
# Variables for Shared Kubernetes Base Module
###############################################################################

variable "namespaces" {
  description = "List of Kubernetes namespaces to create"
  type        = list(string)
  default = [
    "gpu-operator",
    "monitoring",
    "inference",
    "enterprise",
    "gateway",
  ]
}

variable "max_inference_gpus" {
  description = "Maximum number of GPUs allocatable in the inference namespace"
  type        = string
  default     = "8"
}
