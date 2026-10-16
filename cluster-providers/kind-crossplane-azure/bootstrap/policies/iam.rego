package terraform.azure.iam

import rego.v1

# Deny Owner role assignments (use Contributor + User Access Administrator instead)
deny contains msg if {
  ra := input.resource_changes[_]
  ra.type == "azurerm_role_assignment"
  ra.change.after.role_definition_name == "Owner"
  msg := sprintf("DENY [IAM] '%s': Owner role forbidden — use Contributor + User Access Administrator", [ra.address])
}

# Deny role assignments without principal_type set (prevents privilege escalation via group)
deny contains msg if {
  ra := input.resource_changes[_]
  ra.type == "azurerm_role_assignment"
  not ra.change.after.principal_type
  msg := sprintf("DENY [IAM] '%s': must set principal_type to prevent privilege escalation", [ra.address])
}
