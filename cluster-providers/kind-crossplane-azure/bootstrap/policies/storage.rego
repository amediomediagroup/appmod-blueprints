package terraform.azure.storage

import rego.v1

# Deny storage accounts without TLS 1.2
deny contains msg if {
  sa := input.resource_changes[_]
  sa.type == "azurerm_storage_account"
  sa.change.after.min_tls_version != "TLS1_2"
  msg := sprintf("DENY [Storage] '%s': min_tls_version must be TLS1_2", [sa.address])
}

# Deny storage accounts allowing public blob access
deny contains msg if {
  sa := input.resource_changes[_]
  sa.type == "azurerm_storage_account"
  sa.change.after.allow_nested_items_to_be_public == true
  msg := sprintf("DENY [Storage] '%s': public blob access must be disabled", [sa.address])
}
