terraform {
  required_version = ">= 1.3.0"

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

module "amg_grafana" {
  source  = "./managed-grafana-workspace"
  aws_region = var.aws_region
}

module "managed_service_prometheus" {
  source  = "terraform-aws-modules/managed-service-prometheus/aws"
  version = "~> 2.2.2"
  workspace_alias = "aws-observability-accelerator-multicluster"
}
