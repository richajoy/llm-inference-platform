###############################################################################
# GKE Cluster for Enterprise LLM Inference
#
# Creates a private GKE cluster with:
#   - VPC-native networking (alias IPs)
#   - Workload Identity for secure GCP service access
#   - Private cluster with authorized networks
#   - REGULAR release channel for stability
#   - Separate GPU node pool defined in gpu-nodepool.tf
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# -----------------------------------------------------------------------------
# VPC Network
# -----------------------------------------------------------------------------
resource "google_compute_network" "gke_vpc" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
  project                 = var.project_id
}

resource "google_compute_subnetwork" "gke_subnet" {
  name          = "${var.cluster_name}-subnet"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.gke_vpc.id
  ip_cidr_range = var.subnet_cidr

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  private_ip_google_access = true
}

# -----------------------------------------------------------------------------
# Cloud Router + NAT for private nodes to reach the internet
# -----------------------------------------------------------------------------
resource "google_compute_router" "gke_router" {
  name    = "${var.cluster_name}-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.gke_vpc.id
}

resource "google_compute_router_nat" "gke_nat" {
  name                               = "${var.cluster_name}-nat"
  project                            = var.project_id
  router                             = google_compute_router.gke_router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# -----------------------------------------------------------------------------
# GKE Cluster (Control Plane)
# -----------------------------------------------------------------------------
resource "google_container_cluster" "primary" {
  provider = google-beta

  name     = var.cluster_name
  project  = var.project_id
  location = var.zone

  # Use a separately managed node pool (remove_default_node_pool)
  remove_default_node_pool = true
  initial_node_count       = 1

  # Release channel for automatic upgrades
  release_channel {
    channel = "REGULAR"
  }

  # VPC-native networking with alias IPs
  network    = google_compute_network.gke_vpc.id
  subnetwork = google_compute_subnetwork.gke_subnet.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Private cluster configuration
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_cidr
  }

  # Authorized networks for API server access
  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.authorized_networks
      content {
        cidr_block   = cidr_blocks.value.cidr
        display_name = cidr_blocks.value.name
      }
    }
  }

  # Workload Identity for GCP service access from pods
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Logging and monitoring
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = true
    }
  }

  # Addons
  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  # Maintenance window (weekends, off-hours UTC)
  maintenance_policy {
    recurring_window {
      start_time = "2025-01-01T06:00:00Z"
      end_time   = "2025-01-01T14:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }
  }

  # Network policy
  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  # Binary authorization (optional but recommended)
  binary_authorization {
    evaluation_mode = "DISABLED"
  }
}

# -----------------------------------------------------------------------------
# System Node Pool (non-GPU workloads)
# -----------------------------------------------------------------------------
resource "google_container_node_pool" "system" {
  name     = "system-pool"
  project  = var.project_id
  location = var.zone
  cluster  = google_container_cluster.primary.name

  node_count = var.system_node_count

  node_config {
    machine_type = "e2-standard-8"
    disk_size_gb = 100
    disk_type    = "pd-ssd"

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = {
      role = "system"
    }

    taint {
      key    = "role"
      value  = "system"
      effect = "NO_SCHEDULE"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
