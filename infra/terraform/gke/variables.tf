###############################################################################
# Variables for GKE Cluster with GPU Node Pools
###############################################################################

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for the cluster"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for the zonal cluster (A3 Ultra availability)"
  type        = string
  default     = "us-central1-c"
}

variable "cluster_name" {
  description = "Name of the GKE cluster"
  type        = string
  default     = "llm-inference"
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

variable "subnet_cidr" {
  description = "Primary CIDR for the GKE subnet"
  type        = string
  default     = "10.0.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary CIDR for pods"
  type        = string
  default     = "10.4.0.0/14"
}

variable "services_cidr" {
  description = "Secondary CIDR for services"
  type        = string
  default     = "10.8.0.0/20"
}

variable "master_cidr" {
  description = "CIDR block for the GKE master (must be /28)"
  type        = string
  default     = "172.16.0.0/28"
}

variable "authorized_networks" {
  description = "List of CIDR blocks authorized to access the cluster API server"
  type = list(object({
    cidr = string
    name = string
  }))
  default = [
    {
      cidr = "0.0.0.0/0"
      name = "all-access"
    }
  ]
}

# -----------------------------------------------------------------------------
# Node Pools
# -----------------------------------------------------------------------------

variable "system_node_count" {
  description = "Number of system (non-GPU) nodes"
  type        = number
  default     = 2
}

variable "gpu_node_count" {
  description = "Initial number of GPU nodes (A3 Ultra with 8xH100)"
  type        = number
  default     = 1
}

variable "gpu_min_node_count" {
  description = "Minimum GPU nodes for autoscaling"
  type        = number
  default     = 1
}

variable "gpu_max_node_count" {
  description = "Maximum GPU nodes for autoscaling"
  type        = number
  default     = 4
}

variable "gpu_machine_type" {
  description = "Machine type for GPU nodes (a3-ultragpu-8g = 8xH100 SXM)"
  type        = string
  default     = "a3-ultragpu-8g"
}

variable "gpu_disk_size_gb" {
  description = "Boot disk size for GPU nodes in GB"
  type        = number
  default     = 500
}

variable "enable_spot_gpu" {
  description = "Use Spot VMs for GPU nodes (cheaper but preemptible)"
  type        = bool
  default     = false
}
