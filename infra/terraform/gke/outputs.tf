###############################################################################
# Outputs for GKE Cluster
###############################################################################

output "cluster_name" {
  description = "Name of the GKE cluster"
  value       = google_container_cluster.primary.name
}

output "cluster_endpoint" {
  description = "Endpoint for the GKE cluster API server"
  value       = google_container_cluster.primary.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64-encoded CA certificate for the cluster"
  value       = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "cluster_location" {
  description = "Location (zone) of the cluster"
  value       = google_container_cluster.primary.location
}

output "kubeconfig_command" {
  description = "Command to configure kubectl"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone ${google_container_cluster.primary.location} --project ${var.project_id}"
}

output "vpc_network" {
  description = "VPC network name"
  value       = google_compute_network.gke_vpc.name
}

output "subnet_name" {
  description = "Subnet name"
  value       = google_compute_subnetwork.gke_subnet.name
}

output "gpu_nodepool_name" {
  description = "Name of the GPU node pool"
  value       = google_container_node_pool.gpu_h100.name
}

output "connection_info" {
  description = "Quick-start connection info"
  value = <<-EOT

    ============================================================
    GKE Cluster Ready
    ============================================================
    Cluster:       ${google_container_cluster.primary.name}
    Location:      ${google_container_cluster.primary.location}
    GPU Pool:      ${google_container_node_pool.gpu_h100.name}
    GPU Nodes:     ${var.gpu_node_count} (autoscale: ${var.gpu_min_node_count}-${var.gpu_max_node_count})
    Machine Type:  ${var.gpu_machine_type}

    Configure kubectl:
      ${" "}gcloud container clusters get-credentials ${google_container_cluster.primary.name} \
        --zone ${google_container_cluster.primary.location} \
        --project ${var.project_id}

    Next steps:
      1. Run post-install.sh to install Helm + NVIDIA repos
      2. Install GPU Operator: make install-gpu-operator
      3. Deploy inference: make deploy-70b-tp4
    ============================================================
  EOT
}
