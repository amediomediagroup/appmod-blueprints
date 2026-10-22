terraform {
  required_version = ">= 1.11"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
    # Used by the AVM modules and mocked by tests/unit.tftest.hcl.
    # Declared here so `terraform test` can resolve the mock; the lock file
    # already pins azure/azapi.
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.13"
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
