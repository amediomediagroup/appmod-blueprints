package terraform.azure.naming

import rego.v1

# Allowed prefixes per resource type
rg_prefix := "rg-"
kv_prefix := "kv-"
sa_allowed_prefix := "st"
uami_prefix := "id-"

# Deny resource groups without rg- prefix
deny contains msg if {
  r := input.resource_changes[_]
  r.type == "azurerm_resource_group"
  not startswith(r.change.after.name, rg_prefix)
  msg := sprintf("DENY [Naming] Resource group '%s' must start with '%s'", [r.change.after.name, rg_prefix])
}

# Deny Key Vaults without kv- prefix
deny contains msg if {
  r := input.resource_changes[_]
  r.type == "azurerm_key_vault"
  not startswith(r.change.after.name, kv_prefix)
  msg := sprintf("DENY [Naming] Key Vault '%s' must start with '%s'", [r.change.after.name, kv_prefix])
}

# Deny storage accounts without st prefix (Azure storage names are lowercase alphanum only)
deny contains msg if {
  r := input.resource_changes[_]
  r.type == "azurerm_storage_account"
  not startswith(r.change.after.name, sa_allowed_prefix)
  msg := sprintf("DENY [Naming] Storage account '%s' must start with '%s'", [r.change.after.name, sa_allowed_prefix])
}

# Warn: resource names should not contain uppercase letters (Azure convention)
deny contains msg if {
  r := input.resource_changes[_]
  r.type in {"azurerm_resource_group", "azurerm_key_vault", "azurerm_storage_account"}
  r.change.after.name != lower(r.change.after.name)
  msg := sprintf("DENY [Naming] '%s' name '%s' must be lowercase", [r.type, r.change.after.name])
}
