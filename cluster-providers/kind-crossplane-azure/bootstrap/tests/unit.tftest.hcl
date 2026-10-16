# unit.tftest.hcl — Terraform unit tests (variable validation + output shape)
#
# Run locally:
#   cd cluster-providers/kind-crossplane-azure/bootstrap
#   terraform init -backend=false
#   terraform test -filter=tests/unit.tftest.hcl
#
# Uses mock_provider + override_module (standard unit test pattern):
#   - mock_provider  — replace external providers (no Azure/GitHub API calls)
#   - override_module — mock AVM external modules so tests focus on OUR code
#     (variable validations, output logic) not AVM internals.
#
# This is the same pattern as mocking in Go/Python/JS unit tests.
# Integration tests (with real credentials) belong in a separate test file.

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
    acr_name = "ab"
  }
  expect_failures = [var.acr_name]
}

run "acr_name_too_long_fails" {
  command = plan
  variables {
    acr_name = "thisacrnameiswaytoolongandexceedsfiftychars123456"
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

run "acr_name_valid_passes" {
  command = plan
  variables {
    acr_name = "testacr"
  }
}

run "keyvault_name_too_long_fails" {
  command = plan
  variables {
    bootstrap_keyvault_name = "kv-this-name-is-way-too-long-25ch"
  }
  expect_failures = [var.bootstrap_keyvault_name]
}

run "keyvault_name_max_valid_passes" {
  command = plan
  variables {
    bootstrap_keyvault_name = "kv-exactly-24-chars12345"
  }
}

run "workload_name_too_long_fails" {
  command = plan
  variables {
    resource_name_workload = "toolng"
  }
  expect_failures = [var.resource_name_workload]
}

run "workload_name_max_valid_passes" {
  command = plan
  variables {
    resource_name_workload = "plat"
  }
}

# ── Output shape test ─────────────────────────────────────────────────────────
# Verifies try() guards don't crash when managed_identity_client_ids is empty.

run "outputs_safe_on_fresh_state" {
  command = plan

  assert {
    condition     = output.acr_login_server == "testplatformsea.azurecr.io"
    error_message = "acr_login_server must match mock ACR output"
  }
}
