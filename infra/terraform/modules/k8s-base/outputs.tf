###############################################################################
# Outputs for Shared Kubernetes Base Module
###############################################################################

output "namespace_names" {
  description = "List of created namespace names"
  value       = [for ns in kubernetes_namespace.namespaces : ns.metadata[0].name]
}

output "namespaces" {
  description = "Map of namespace name to namespace metadata"
  value = {
    for ns in kubernetes_namespace.namespaces : ns.metadata[0].name => {
      name   = ns.metadata[0].name
      labels = ns.metadata[0].labels
      uid    = ns.metadata[0].uid
    }
  }
}
