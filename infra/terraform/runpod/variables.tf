###############################################################################
# Variables for RunPod GPU Pod Provisioning
###############################################################################

variable "runpod_api_key" {
  description = "RunPod API key for authentication"
  type        = string
  sensitive   = true
}

variable "pod_count" {
  description = "Number of GPU pods to provision (default: 1 for single 8xH100 SXM pod)"
  type        = number
  default     = 1
}

variable "pod_name_prefix" {
  description = "Prefix for pod names (e.g. llm-node)"
  type        = string
  default     = "llm-k8s-node"
}

variable "gpu_type" {
  description = "GPU type ID - defaults to NVIDIA H100 SXM for inference workloads"
  type        = string
  default     = "NVIDIA H100 SXM"

  validation {
    condition     = contains(["NVIDIA A100 80GB PCIe", "NVIDIA H100 SXM", "NVIDIA H100 80GB HBM3", "NVIDIA A100-SXM4-80GB"], var.gpu_type)
    error_message = "GPU type must be a supported RunPod GPU type."
  }
}

variable "gpu_count" {
  description = "Number of GPUs per pod (default: 8 for full H100 SXM node)"
  type        = number
  default     = 8

  validation {
    condition     = var.gpu_count >= 1 && var.gpu_count <= 8
    error_message = "GPU count must be between 1 and 8."
  }
}

variable "container_image" {
  description = "Docker container image for the pods"
  type        = string
  default     = "nvidia/cuda:12.4.1-devel-ubuntu22.04"
}

variable "container_disk_size_gb" {
  description = "Container disk size in GB"
  type        = number
  default     = 50
}

variable "volume_size_gb" {
  description = "Persistent volume size in GB for model weights and data"
  type        = number
  default     = 500
}

variable "network_volume_size_gb" {
  description = "Network volume size in GB for shared model weight storage (survives pod restarts)"
  type        = number
  default     = 500
}

variable "volume_mount_path" {
  description = "Mount path for the persistent volume inside the container"
  type        = string
  default     = "/workspace"
}

variable "cloud_type" {
  description = "Cloud type: SECURE for on-demand, COMMUNITY for spot/community"
  type        = string
  default     = "SECURE"

  validation {
    condition     = contains(["SECURE", "COMMUNITY"], var.cloud_type)
    error_message = "Cloud type must be SECURE or COMMUNITY."
  }
}

variable "data_center_id" {
  description = "Preferred data center ID (e.g. US-TX-3). Leave empty for auto-selection."
  type        = string
  default     = ""
}

variable "min_vcpu_count" {
  description = "Minimum vCPU count per pod"
  type        = number
  default     = 8
}

variable "min_memory_gb" {
  description = "Minimum memory in GB per pod (250GB+ recommended for 8xH100)"
  type        = number
  default     = 250
}

variable "ports" {
  description = "Ports to expose on the pod (HTTP and TCP)"
  type        = string
  default     = "6443/tcp,8000/http,8001/http,22/tcp,30000/tcp,30001/tcp,30002/tcp,30003/tcp,30004/tcp,30005/tcp"
}

variable "start_ssh" {
  description = "Whether to start SSH server on the pod"
  type        = bool
  default     = true
}

variable "ssh_public_key" {
  description = "SSH public key for pod access"
  type        = string
  default     = ""
}

variable "environment_variables" {
  description = "Environment variables to set in the pods"
  type        = map(string)
  default     = {}
}
