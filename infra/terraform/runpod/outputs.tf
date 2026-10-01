###############################################################################
# Outputs for RunPod GPU Pod Provisioning
###############################################################################

output "pod_ids" {
  description = "IDs of the provisioned RunPod pods"
  value       = runpod_pod.gpu_node[*].id
}

output "pod_ips" {
  description = "Public IP addresses of the provisioned pods"
  value       = runpod_pod.gpu_node[*].machine.ip
}

output "ssh_commands" {
  description = "SSH connection commands for each pod"
  value = [
    for pod in runpod_pod.gpu_node : "ssh root@${pod.machine.ip} -i ~/.ssh/id_runpod"
  ]
}

output "api_endpoints" {
  description = "API endpoints for each pod (port 8000)"
  value = [
    for pod in runpod_pod.gpu_node : "http://${pod.machine.ip}:8000"
  ]
}

output "k3s_api_endpoints" {
  description = "Kubernetes API server endpoints for each pod"
  value = [
    for pod in runpod_pod.gpu_node : "https://${pod.machine.ip}:6443"
  ]
}

output "network_volume_id" {
  description = "ID of the network volume for model weight storage"
  value       = runpod_network_volume.model_storage.id
}

output "network_volume_name" {
  description = "Name of the network volume"
  value       = runpod_network_volume.model_storage.name
}

output "gpu_summary" {
  description = "Summary of GPU configuration"
  value = {
    gpu_type  = var.gpu_type
    gpu_count = var.gpu_count
    pod_count = var.pod_count
    total_gpus = var.gpu_count * var.pod_count
  }
}

output "connection_info" {
  description = "Quick-start connection info"
  value = <<-EOT

    ============================================================
    RunPod Infrastructure Ready
    ============================================================
    Pods:          ${var.pod_count}
    GPUs per Pod:  ${var.gpu_count}x ${var.gpu_type}
    Total GPUs:    ${var.gpu_count * var.pod_count}
    Network Vol:   ${var.network_volume_size_gb}GB

    Next steps:
      1. SSH into the pod:  ${length(runpod_pod.gpu_node) > 0 ? "ssh root@${runpod_pod.gpu_node[0].machine.ip} -i ~/.ssh/id_runpod" : "N/A"}
      2. Run k3s bootstrap: bash /workspace/infra/k8s-bootstrap/k3s-install.sh
      3. Run post-install:  bash /workspace/infra/k8s-bootstrap/post-install.sh
    ============================================================
  EOT
}
