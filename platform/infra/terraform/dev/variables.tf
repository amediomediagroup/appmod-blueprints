variable "aws_region" {
  description = "AWS Region"
  type        = string
  default = "us-west-2"
}

variable "tfe_project" {
  description = "Unique project name for terraform lock file"
  type        = string
  default = "eks-accelerator"
}

variable "cluster_name" {
  description = "Name of cluster - used by Terratest for e2e test automation"
  type        = string
  default     = "eks-cluster-with-vpc"

  validation {
    # cluster name is used as prefix on eks_blueprint module and cannot be >25 characters
    condition     = can(regex("^[a-zA-Z][-a-zA-Z0-9]{3,24}$", var.cluster_name))
    error_message = "Cluster name is used as a prefix-name for other resources. Max size is 25 chars and must satisfy regular expression pattern: '[a-zA-Z][-a-zA-Z0-9]{3,19}'."
  }
}

variable "eks_cluster_id" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "eks-cluster-with-vpc"
}

variable "managed_prometheus_workspace_id" {
  description = "Amazon Managed Service for Prometheus Workspace ID"
  type        = string
  default     = ""
}

variable "managed_grafana_workspace_id" {
  description = "Amazon Managed Grafana Workspace ID"
  type        = string
}

variable "grafana_api_key" {
  description = "API key for authorizing the Grafana provider to make changes to Amazon Managed Grafana"
  type        = string
  sensitive   = true
}
