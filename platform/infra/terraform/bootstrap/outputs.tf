output "eks-accelerator-bootstrap-state-bucket" {
  description = "EKS accelerator state bucket"
  value       = aws_s3_bucket.terraform-states-s3-bucket.id
}

output "eks-accelerator-bootstrap-ddb-lock-table" {
  description = "EKS accelerator DynamoDB lock table"
  value       = aws_dynamodb_table.terraform-lock.name
}

output "amg_workspace_id" {
  description = "Amazon Managed Grafana Workspace ID"
  value       = module.amg_grafana.grafana_workspace_id
}

output "amp_workspace_id" {
  description = "Amazon Managed prometheus Workspace ID"
  value       = module.managed_service_prometheus.workspace_id
}
