package terraform.azure.keyvault

import rego.v1

# Deny Key Vault without RBAC authorization
deny contains msg if {
  kv := input.resource_changes[_]
  kv.type == "azurerm_key_vault"
  kv.change.after.enable_rbac_authorization != true
  msg := sprintf("DENY [KV] '%s': must use RBAC authorization (not access policies)", [kv.address])
}

# Deny Key Vault without soft delete
deny contains msg if {
  kv := input.resource_changes[_]
  kv.type == "azurerm_key_vault"
  kv.change.after.soft_delete_retention_days < 7
  msg := sprintf("DENY [KV] '%s': soft_delete_retention_days must be >= 7", [kv.address])
}

# Deny Key Vault secrets without content_type
deny contains msg if {
  s := input.resource_changes[_]
  s.type == "azurerm_key_vault_secret"
  not s.change.after.content_type
  msg := sprintf("DENY [KV Secret] '%s': must set content_type", [s.address])
}

# Deny Key Vault secrets without expiration
deny contains msg if {
  s := input.resource_changes[_]
  s.type == "azurerm_key_vault_secret"
  not s.change.after.expiration_date
  msg := sprintf("DENY [KV Secret] '%s': must set expiration_date", [s.address])
}
