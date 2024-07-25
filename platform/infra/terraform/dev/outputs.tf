output "dev_cluster_name" {
  description = "EKS DEV Cluster name"
  value       = module.eks_dev_cluster_with_vpc.eks_cluster_id
}

output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = module.eks_dev_cluster_with_vpc.configure_kubectl
}

output "amp_workspace_id" {
  description = "Amazon Managed Prometheus Workspace ID"
  value       = module.eks_dev_observability_accelerator.managed_prometheus_workspace_id
}

output "argocd_dev_load_balancer_url" {
  value = data.kubernetes_service.argocd_dev_server.status[0].load_balancer[0].ingress[0].hostname
}

output "argocd_dev_initial_admin_secret" {
  value = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d"
}
