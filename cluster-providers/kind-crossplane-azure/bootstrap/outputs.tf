output "platform_uami_client_id" {
  description = "Client ID of the platform UAMI (write identity) used by GitHub Actions and Kind Workload Identity."
  value       = module.cicd_bootstrap.managed_identity_client_ids[var.github_environment]["write"]
  sensitive   = true
}

output "bootstrap_keyvault_uri" {
  description = "URI of the Bootstrap Key Vault."
  value       = azurerm_key_vault.bootstrap.vault_uri
}

output "hub_resource_group_id" {
  description = "ARM resource ID of the hub cluster resource group."
  value       = azurerm_resource_group.hub.id
}

output "tenant_id" {
  description = "Azure Entra tenant ID (from AVM module)."
  value       = module.cicd_bootstrap.tenant_id
  sensitive   = true
}
