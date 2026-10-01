###############################################################################
# A3 Ultra GPU Node Pool - 8x NVIDIA H100 SXM per node
#
# The a3-ultragpu-8g machine type provides:
#   - 8x NVIDIA H100 80GB SXM GPUs
#   - NVLink/NVSwitch for high-bandwidth GPU-to-GPU communication
#   - 208 vCPUs, 1872 GB RAM
#   - 6 TB local SSD
#   - GPUDirect-TCPXO for multi-node training/inference
###############################################################################

resource "google_container_node_pool" "gpu_h100" {
  provider = google-beta

  name     = "gpu-h100-pool"
  project  = var.project_id
  location = var.zone
  cluster  = google_container_cluster.primary.name

  # Initial node count
  node_count = var.gpu_node_count

  # Autoscaling configuration
  autoscaling {
    min_node_count = var.gpu_min_node_count
    max_node_count = var.gpu_max_node_count
  }

  node_config {
    machine_type = var.gpu_machine_type
    disk_size_gb = var.gpu_disk_size_gb
    disk_type    = "pd-ssd"
    image_type   = "COS_CONTAINERD"

    # Spot VM option for cost savings
    spot = var.enable_spot_gpu

    # GPU configuration - A3 Ultra has 8xH100 built into the machine type
    # No explicit guest_accelerator block needed for a3-ultragpu-8g

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    # Workload Identity
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # Labels for node selection
    labels = {
      "role"                        = "gpu"
      "gpu-type"                    = "h100-sxm"
      "nvidia.com/gpu.product"      = "NVIDIA-H100-80GB-HBM3"
      "nvidia.com/gpu.count"        = "8"
    }

    # Taint GPU nodes so only GPU workloads schedule here
    taint {
      key    = "nvidia.com/gpu"
      value  = "present"
      effect = "NO_SCHEDULE"
    }

    # Resource labels for cost attribution
    resource_labels = {
      "team"        = "ml-infra"
      "environment" = "production"
      "gpu-type"    = "h100"
    }

    # Local SSD for fast model loading and KV cache
    local_nvme_ssd_block_config {
      local_ssd_count = 16
    }

    # Reservation affinity (if you have reserved capacity)
    # reservation_affinity {
    #   consume_reservation_type = "SPECIFIC_RESERVATION"
    #   key                      = "compute.googleapis.com/reservation-name"
    #   values                   = ["your-h100-reservation"]
    # }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # Surge upgrade settings - careful with GPU nodes
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  # Placement policy for GPU topology awareness
  placement_policy {
    type         = "COMPACT"
    policy_name  = "${var.cluster_name}-gpu-placement"
  }

  lifecycle {
    ignore_changes = [
      node_count, # Managed by autoscaler
    ]
  }
}
