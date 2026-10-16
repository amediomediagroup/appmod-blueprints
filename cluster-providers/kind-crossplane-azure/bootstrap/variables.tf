# ── Azure ─────────────────────────────────────────────────────────────────────

variable "subscription_id" {
  type        = string
  description = "Azure subscription ID for the hub cluster."
  sensitive   = true
}

variable "tenant_id" {
  type        = string
  description = "Azure Entra ID tenant ID."
  sensitive   = true
}

variable "location" {
  type        = string
  description = "Azure region for all bootstrap resources (e.g. southeastasia)."
}

variable "bootstrap_resource_group" {
  type        = string
  description = "Resource group for bootstrap infra (Bootstrap KV, UAMIs). Created by AVM module."
  default     = null
  nullable    = true
}

variable "hub_resource_group" {
  type        = string
  description = "Resource group where the hub AKS cluster will be created."
}

variable "hub_cluster_name" {
  type        = string
  description = "Hub AKS cluster name."
}

variable "bootstrap_keyvault_name" {
  type        = string
  description = "Name for the Bootstrap Key Vault (max 24 chars, globally unique)."

  validation {
    condition     = length(var.bootstrap_keyvault_name) <= 24
    error_message = "Key Vault name must be 24 characters or fewer."
  }
}

variable "resource_prefix" {
  type        = string
  default     = ""
  description = "Optional resource prefix for platform resources."
}

# ── Platform config ────────────────────────────────────────────────────────────

variable "platform_domain" {
  type        = string
  description = "Platform ingress domain."
  sensitive   = true
}

variable "repo_revision" {
  type        = string
  default     = "main"
  description = "Git branch to deploy from."
}

# ── AVM module naming ──────────────────────────────────────────────────────────
# AVM module constructs resource names from these three components.

variable "resource_name_workload" {
  type        = string
  description = "Workload name segment for AVM resource naming (e.g. platform)."
  default     = "platform"
}

variable "resource_name_environment" {
  type        = string
  description = "Environment name segment for AVM resource naming (e.g. prod)."
  default     = "prod"
}

variable "resource_name_location_short" {
  type        = string
  description = "Short location code for AVM resource naming (e.g. sea for southeastasia)."
}

# ── GitHub ─────────────────────────────────────────────────────────────────────

variable "github_org" {
  type        = string
  description = "GitHub organization name."
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name."
}

variable "github_environment" {
  type        = string
  default     = "azure-hub"
  description = "GitHub Actions environment name for the Azure hub deployment."
}
