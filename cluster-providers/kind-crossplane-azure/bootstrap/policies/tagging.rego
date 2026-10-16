package terraform.azure.tagging

import rego.v1

# Required tags for all taggable resources
required_tags := {"environment", "managed-by"}

# Resource types that must have tags
taggable_types := {
  "azurerm_resource_group",
  "azurerm_key_vault",
  "azurerm_storage_account",
  "azurerm_user_assigned_identity",
}

# Deny resources missing required tags
deny contains msg if {
  r := input.resource_changes[_]
  r.type in taggable_types
  tag := required_tags[_]
  not r.change.after.tags[tag]
  msg := sprintf("DENY [Tagging] '%s' missing required tag '%s'", [r.address, tag])
}

# Deny resources with no tags block at all
deny contains msg if {
  r := input.resource_changes[_]
  r.type in taggable_types
  not r.change.after.tags
  msg := sprintf("DENY [Tagging] '%s' has no tags block — required: %v", [r.address, required_tags])
}
