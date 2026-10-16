terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.10"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
  }

  # State stored in Azure Blob Storage.
  # The storage account is created by scripts/init.sh before the first apply.
  backend "azurerm" {}
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}

# GITHUB_TOKEN env var — set in CI via gh auth token or GitHub App token
provider "github" {
  owner = var.github_org
}
