terraform {
  required_version = ">= 1.3.0"

  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

module "eks_cluster_with_vpc" {
  source  = "../terraform-aws-observability-accelerator/examples/eks-cluster-with-vpc"
  aws_region = var.aws_region
  cluster_name = var.cluster_name
}

module "eks_observability_accelerator" {
  source  = "../terraform-aws-observability-accelerator/examples/existing-cluster-with-base-and-infra"
  eks_cluster_id = module.eks_cluster_with_vpc.eks_cluster_id
  aws_region = var.aws_region
  managed_grafana_workspace_id = var.managed_grafana_workspace_id
  grafana_api_key = var.grafana_api_key
  # depends_on = [module.eks_cluster_with_vpc]
}


