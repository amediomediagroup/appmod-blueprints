# Terraform unit tests — variable boundaries and missing-identity fallback.
#
# Requires Terraform >= 1.11. From the bootstrap directory:
#   terraform init -backend=false -lockfile=readonly
#   terraform test -filter=tests/unit.tftest.hcl
#
# Providers and external AVM modules are mocked; no cloud credentials are used.

mock_provider "azurerm" {}
mock_provider "azapi" {}
mock_provider "github" {}

# Mock AVM modules — these are external dependencies.
# Override their outputs so our variable validations and outputs are isolated.
override_module {
  target = module.cicd_bootstrap
  outputs = {
    resource_id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test"
    tenant_id                   = "00000000-0000-0000-0000-000000000000"
    managed_identity_client_ids = {}
  }
}

override_module {
  target = module.acr
  outputs = {
    login_server = "testplatformsea.azurecr.io"
    resource_id  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ContainerRegistry/registries/testplatformsea"
  }
}

# ── Shared valid defaults ─────────────────────────────────────────────────────
variables {
  subscription_id              = "00000000-0000-0000-0000-000000000000"
  tenant_id                    = "00000000-0000-0000-0000-000000000000"
  location                     = "southeastasia"
  hub_resource_group           = "rg-peeks-hub-test"
  hub_cluster_name             = "peeks-hub-test"
  bootstrap_keyvault_name      = "kv-bootstrap-test"
  platform_domain              = "test.example.com"
  github_org                   = "test-org"
  github_repo                  = "test-repo"
  github_environment           = "azure-hub"
  acr_name                     = "testplatformsea"
  resource_name_location_short = "sea"
  resource_name_workload       = "plat"
  resource_name_environment    = "dev"
}

# ── Variable validation tests ─────────────────────────────────────────────────

run "acr_name_too_short_fails" {
  command = plan
  variables {
    acr_name = "abcd" # 4 characters: one below the minimum.
  }
  expect_failures = [var.acr_name]
}

run "acr_name_too_long_fails" {
  command = plan
  variables {
    acr_name = join("", [for _ in range(51) : "a"])
  }
  expect_failures = [var.acr_name]
}

run "acr_name_with_hyphen_fails" {
  command = plan
  variables {
    acr_name = "test-acr-name"
  }
  expect_failures = [var.acr_name]
}


run "keyvault_name_too_long_fails" {
  command = plan
  variables {
    bootstrap_keyvault_name = join("", [for _ in range(25) : "a"])
  }
  expect_failures = [var.bootstrap_keyvault_name]
}


run "workload_name_too_long_fails" {
  command = plan
  variables {
    resource_name_workload = "plats" # 5 characters: one above the maximum.
  }
  expect_failures = [var.resource_name_workload]
}


# The maximum valid names must plan successfully even before an identity exists.
# Verify the try() fallback, not an echoed output from the mocked ACR module.

run "outputs_safe_on_fresh_state" {
  command = plan
  variables {
    acr_name                = join("", [for _ in range(50) : "a"])
    bootstrap_keyvault_name = join("", [for _ in range(24) : "a"])
    resource_name_workload  = "plat"
  }

  assert {
    condition     = output.platform_uami_client_id == null
    error_message = "A missing environment identity must produce a null client ID."
  }
}
