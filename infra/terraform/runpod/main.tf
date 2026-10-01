###############################################################################
# RunPod GPU Pod Provisioning
#
# Provisions a single 8xH100 SXM GPU pod on RunPod for running k3s with
# GPU-accelerated LLM inference workloads.
###############################################################################

# -----------------------------------------------------------------------------
# Network Volume for persistent model weight storage
# Survives pod restarts and can be reattached to new pods.
# -----------------------------------------------------------------------------
resource "runpod_network_volume" "model_storage" {
  name       = "${var.pod_name_prefix}-models"
  size       = var.network_volume_size_gb
  region     = var.data_center_id != "" ? var.data_center_id : "US-TX-3"
}

# -----------------------------------------------------------------------------
# GPU Pod - Single 8xH100 SXM for inference
# -----------------------------------------------------------------------------
resource "runpod_pod" "gpu_node" {
  count = var.pod_count

  name       = "${var.pod_name_prefix}-${count.index + 1}"
  image_name = var.container_image
  gpu_type   = var.gpu_type
  gpu_count  = var.gpu_count
  cloud_type = var.cloud_type

  # Resource allocation
  min_vcpu_count   = var.min_vcpu_count
  min_memory_in_gb = var.min_memory_gb

  # Storage
  container_disk_in_gb = var.container_disk_size_gb
  volume_in_gb         = var.volume_size_gb
  volume_mount_path    = var.volume_mount_path

  # Attach network volume for model weights
  network_volume_id = runpod_network_volume.model_storage.id

  # Networking - expose k3s API, service ports, and NodePort range
  ports = var.ports

  # SSH access for cluster setup
  start_ssh = var.start_ssh

  # Data center preference
  data_center_id = var.data_center_id != "" ? var.data_center_id : null

  # Docker startup command: keep the container running and install essentials
  docker_args = <<-EOT
    bash -c '
      apt-get update && apt-get install -y curl wget sudo openssh-server iptables &&
      mkdir -p /run/sshd && /usr/sbin/sshd &&
      echo "Pod ${count.index + 1} ready" &&
      sleep infinity
    '
  EOT

  # Environment variables for k3s setup
  env {
    key   = "NODE_INDEX"
    value = tostring(count.index + 1)
  }

  env {
    key   = "TOTAL_NODES"
    value = tostring(var.pod_count)
  }

  # Pass through any additional environment variables
  dynamic "env" {
    for_each = var.environment_variables
    content {
      key   = env.key
      value = env.value
    }
  }
}
