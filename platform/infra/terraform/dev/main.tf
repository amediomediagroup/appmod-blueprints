terraform {
  required_version = ">= 1.3.0"

  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.0.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

module "eks_dev_cluster_with_vpc" {
  source  = "../terraform-aws-observability-accelerator/examples/eks-cluster-with-vpc"
  aws_region = var.aws_region
  cluster_name = var.cluster_name
}

module "eks_dev_observability_accelerator" {
  source  = "../terraform-aws-observability-accelerator/examples/existing-cluster-with-base-and-infra"
  eks_cluster_id = module.eks_dev_cluster_with_vpc.eks_cluster_id
  aws_region = var.aws_region
  managed_grafana_workspace_id = var.managed_grafana_workspace_id
  grafana_api_key = var.grafana_api_key
}

data "aws_eks_cluster_auth" "dev_cluster_auth" {
  name = module.eks_dev_cluster_with_vpc.eks_cluster_id
}

data "aws_eks_cluster" "dev_cluster_name" {
  name = module.eks_dev_cluster_with_vpc.eks_cluster_id
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.dev_cluster_name.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.dev_cluster_name.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.dev_cluster_auth.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.dev_cluster_name.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.dev_cluster_name.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.dev_cluster_auth.token
  }
}

provider "kubectl" {
  host                   = data.aws_eks_cluster.dev_cluster_name.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.dev_cluster_name.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.dev_cluster_auth.token
  load_config_file       = false
}

resource "helm_release" "dev_argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.3.10"
  namespace        = "argocd"
  create_namespace = true

  set {
    name  = "server.service.type"
    value = "LoadBalancer"
  }

  set {
    name  = "server.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
    value = "nlb"
  }
}

data "kubernetes_service" "argocd_dev_server" {
  metadata {
    name      = "argocd-server"
    namespace = helm_release.dev_argocd.namespace
  }
}

# resource "helm_release" "app_of_apps" {
#   name             = "app-of-apps"
#   chart            = "../deployment/envs/dev"
#   create_namespace = true
#   depends_on       = [helm_release.argocd]
# }
