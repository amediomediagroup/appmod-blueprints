# unit.tftest.hcl — Terraform unit tests using mock providers
#
# Run locally:
#   cd cluster-providers/kind-crossplane-azure/bootstrap
#   terraform init -backend=false
#   terraform test -filter=tests/unit.tftest.hcl
#
# These tests use mock_provider so no Azure/GitHub credentials are needed.
# Tests catch validation errors and output shape regressions before CI plan.

mock_provider "azurerm" {}
mock_provider "github"  {}

# azapi mock must provide azapi_client_config data source
# — AVM cicd_bootstrap module uses it internally to resolve subscription/tenant IDs
mock_provider "azapi" {
  mock_data "azapi_client_config" {
    defaults = {
      subscription_id          = "00000000-0000-0000-0000-000000000000"
      subscription_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000"
      tenant_id                = "00000000-0000-0000-0000-000000000000"
      object_id                = "00000000-0000-0000-0000-000000000000"
    }
  }
}

# ── Shared valid defaults ─────────────────────────────────────────────────────
# Override per test only what that test is validating.
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
    acr_name = "ab"   # min 5 chars
  }
  expect_failures = [var.acr_name]
}

run "acr_name_too_long_fails" {
  command = plan
  variables {
    acr_name = "thisacrnameiswaytoolongandexceedsfiftychars123456"   # > 50 chars
  }
  expect_failures = [var.acr_name]
}

run "acr_name_with_hyphen_fails" {
  command = plan
  variables {
    acr_name = "test-acr-name"   # hyphens not allowed
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
    bootstrap_keyvault_name = "kv-this-name-is-way-too-long-25ch"   # > 24 chars
  }
  expect_failures = [var.bootstrap_keyvault_name]
}

run "keyvault_name_max_valid_passes" {
  command = plan
  variables {
    bootstrap_keyvault_name = "kv-exactly-24-chars12345"   # exactly 24 chars
  }
}

run "workload_name_too_long_fails" {
  command = plan
  variables {
    resource_name_workload = "toolng"   # > 4 chars
  }
  expect_failures = [var.resource_name_workload]
}

run "workload_name_max_valid_passes" {
  command = plan
  variables {
    resource_name_workload = "plat"   # exactly 4 chars
  }
}

# ── Output shape tests ────────────────────────────────────────────────────────
# Verify that outputs don't crash on fresh state (empty managed_identity_client_ids).
# The try() guard in outputs.tf and main.tf must handle this gracefully.

run "outputs_safe_on_fresh_state" {
  command = plan

  # With mock provider, managed_identity_client_ids will be an empty map.
  # These assertions verify try() catches the invalid index without crashing.
  assert {
    condition     = output.bootstrap_keyvault_uri != null
    error_message = "bootstrap_keyvault_uri must not be null"
  }

  assert {
    condition     = output.hub_resource_group_id != null
    error_message = "hub_resource_group_id must not be null"
  }

  assert {
    condition     = output.acr_login_server != null
    error_message = "acr_login_server must not be null"
  }
}
