output "cluster_name" {
  description = "EKS Cluster name which is the EKS cluster id"
  value       = module.eks_cluster_with_vpc.eks_cluster_id
}

output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = module.eks_cluster_with_vpc.configure_kubectl
}

output "amp_workspace_id" {
  description = "Amazon Managed Prometheus Workspace ID"
  value       = module.eks_observability_accelerator.managed_prometheus_workspace_id
}