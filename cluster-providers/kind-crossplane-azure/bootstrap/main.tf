# ─────────────────────────────────────────────────────────────────────────────
# Azure Bootstrap — GitHub CI/CD for kind-crossplane-azure provider
#
# Uses the official Azure Verified Module (AVM) for GitHub CI/CD bootstrap:
# https://registry.terraform.io/modules/Azure/avm-ptn-alz-application-landing-zone-cicd-bootstrap-github
#
# The AVM module creates:
#   - GitHub environment (azure-hub)
#   - User-Assigned Managed Identity per environment (plan/apply split)
#   - Federated credentials: GitHub env ↔ UAMI (OIDC, no client secret)
#
# This file additionally creates:
#   - Bootstrap Key Vault (stores all platform config — zero PII in code)
#   - Hub resource group (where AKS will be provisioned)
#   - Role assignment: UAMI → Key Vault Secrets User
#   - platform-config secret in Bootstrap KV
#   - GitHub secrets: AZURE_CLIENT_ID, AZURE_TENANT_ID, BOOTSTRAP_KV_NAME
# ─────────────────────────────────────────────────────────────────────────────

data "azurerm_client_config" "current" {}

# ── 1. AVM: GitHub CI/CD Bootstrap ────────────────────────────────────────────
# Creates GitHub environment + UAMIs + federated credentials

# checkov:skip=CKV_TF_1:AVM module from Terraform Registry — commit hash not supported, version pinned instead
module "cicd_bootstrap" {
  source  = "Azure/avm-ptn-alz-application-landing-zone-cicd-bootstrap-github/azure"
  version = "0.1.1"

  github_organization_name = var.github_org
  location                 = var.location
  deployment_mode          = "other" # Taskfile-based, not Terraform/Bicep
  enable_telemetry         = false

  resource_name_workload       = var.resource_name_workload
  resource_name_environment    = var.resource_name_environment
  resource_name_location_short = var.resource_name_location_short

  # No self-hosted runners — use GitHub-hosted ubuntu-latest
  runner_use_self_hosted = false

  # One environment: azure-hub
  environments = {
    (var.github_environment) = {
      display_order = 1
      display_name  = "Azure Hub"
      identities = {
        # "write" identity = the one used for apply (task install)
        write = {
          role_assignments = {
            contributor = {
              role_definition_id_or_name = "Contributor"
            }
          }
        }
      }
    }
  }

  # Use existing repo — do not create a new one
  github_create_main_repository = false
}

# ── 2. Hub Resource Group ─────────────────────────────────────────────────────
# Pre-create RG where Crossplane will provision AKS + other resources.

resource "azurerm_resource_group" "hub" {
  name     = var.hub_resource_group
  location = var.location
  tags = {
    environment  = var.resource_name_environment
    "managed-by" = "terraform"
  }
}

# Grant the "write" UAMI contributor on hub RG so Crossplane can create resources
resource "azurerm_role_assignment" "uami_hub_contributor" {
  scope                = azurerm_resource_group.hub.id
  role_definition_name = "Contributor"
  principal_id         = data.azurerm_user_assigned_identity.platform_write.principal_id
}

data "azurerm_user_assigned_identity" "platform_write" {
  # AVM module names the identity based on resource_name_workload/environment/location.
  # Naming pattern observed from AVM v0.1.1 source:
  #   <workload>-<environment>-<location_short>-write-id
  # TODO: verify this name after first `terraform plan` by checking the AVM-managed RG.
  name                = "${var.resource_name_workload}-${var.resource_name_environment}-${var.resource_name_location_short}-write-id"
  resource_group_name = module.cicd_bootstrap.resource_id != null ? split("/", module.cicd_bootstrap.resource_id)[4] : var.bootstrap_resource_group

  depends_on = [module.cicd_bootstrap]
}

# ── 3. Bootstrap Key Vault ────────────────────────────────────────────────────
# Stores all platform config — zero PII in any committed file.

resource "azurerm_key_vault" "bootstrap" {
  name                = var.bootstrap_keyvault_name
  location            = var.location
  resource_group_name = split("/", module.cicd_bootstrap.resource_id)[4] # AVM's RG
  tenant_id           = module.cicd_bootstrap.tenant_id
  sku_name            = "standard"
  tags = {
    environment  = var.resource_name_environment
    "managed-by" = "terraform"
  }

  rbac_authorization_enabled = true # renamed from enable_rbac_authorization in azurerm v4
  soft_delete_retention_days = 7
  purge_protection_enabled   = true # CKV_AZURE_42 + CKV_AZURE_110

  # checkov:skip=CKV_AZURE_189:Bootstrap KV requires public access — GitHub-hosted runners are not in Azure VNet
  # checkov:skip=CKV2_AZURE_32:Private endpoint not applicable — VNet doesn't exist at bootstrap phase
  # checkov:skip=CKV_AZURE_109:Allow required for GitHub-hosted runners — AzureServices bypass doesn't cover GitHub Actions
  public_network_access_enabled = true

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }

  depends_on = [module.cicd_bootstrap]
}

# Grant Terraform runner (initial bootstrap identity) write access to seed secrets
resource "azurerm_role_assignment" "runner_kv_officer" {
  scope                = azurerm_key_vault.bootstrap.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Grant platform UAMI read access to Bootstrap KV
resource "azurerm_role_assignment" "uami_kv_reader" {
  scope                = azurerm_key_vault.bootstrap.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = data.azurerm_user_assigned_identity.platform_write.principal_id

  depends_on = [module.cicd_bootstrap]
}

# ── 4. Seed platform-config ────────────────────────────────────────────────────
# All platform config lives here. No PII ever committed to git.

resource "azurerm_key_vault_secret" "platform_config" {
  name            = "platform-config"
  key_vault_id    = azurerm_key_vault.bootstrap.id
  content_type    = "application/json"            # CKV_AZURE_114
  expiration_date = timeadd(timestamp(), "8760h") # CKV_AZURE_41 — 1 year

  value = jsonencode({
    subscriptionId = var.subscription_id
    tenantId       = var.tenant_id
    location       = var.location
    domain         = var.platform_domain
    resourceGroup  = var.hub_resource_group
    repoUrl        = "https://github.com/${var.github_org}/${var.github_repo}.git"
    repoRevision   = var.repo_revision
    clusterName    = var.hub_cluster_name
    uamiClientId   = try(module.cicd_bootstrap.managed_identity_client_ids[var.github_environment]["write"], "")
    resourcePrefix = var.resource_prefix
    acrLoginServer = module.acr.login_server
  })

  depends_on = [azurerm_role_assignment.runner_kv_officer]

  lifecycle {
    # Don't overwrite on replan — preserves overlay_repo_url set post-install.
    # expiration_date uses timestamp() which is non-deterministic — ignore to prevent
    # perpetual drift (every plan would show "1 to update" otherwise).
    ignore_changes = [value, expiration_date]
  }
}

# ── 5. Azure Container Registry ───────────────────────────────────────────────
# All platform container images stored here.
# Platform UAMI gets AcrPull; bootstrap runner gets AcrPush (for image import).
# checkov:skip=CKV_TF_1:AVM Registry module from Terraform Registry — commit hash not applicable

# checkov:skip=CKV_TF_1:AVM module from Terraform Registry
module "acr" {
  source  = "Azure/avm-res-containerregistry-registry/azurerm"
  version = "0.8.0"

  name                = var.acr_name
  resource_group_name = split("/", module.cicd_bootstrap.resource_id)[4]
  location            = var.location
  sku                 = "Premium" # Premium: geo-replication, private endpoint, retention
  enable_telemetry    = false

  # RBAC only — no admin account (CKV_AZURE_137)
  admin_enabled = false

  # Allow CI runners (GitHub-hosted) to push/pull during bootstrap
  # checkov:skip=CKV_AZURE_139:Bootstrap ACR needs public access for GitHub-hosted runners
  public_network_access_enabled = true

  tags = {
    environment  = var.resource_name_environment
    "managed-by" = "terraform"
  }

  # Grant platform UAMI (write identity) AcrPull — used by AKS to pull images
  role_assignments = {
    acr_pull = {
      role_definition_id_or_name = "AcrPull"
      principal_id               = data.azurerm_user_assigned_identity.platform_write.principal_id
    }
    acr_push = {
      # Bootstrap runner (CI) can push/import images
      role_definition_id_or_name = "AcrPush"
      principal_id               = data.azurerm_client_config.current.object_id
    }
  }

  depends_on = [module.cicd_bootstrap]
}

# ── 6. GitHub Secrets ─────────────────────────────────────────────────────────
# Only 3 secrets. Everything else comes from Bootstrap KV at runtime.

resource "github_actions_environment_secret" "client_id" {
  repository      = var.github_repo
  environment     = var.github_environment
  secret_name     = "AZURE_CLIENT_ID"
  plaintext_value = try(module.cicd_bootstrap.managed_identity_client_ids[var.github_environment]["write"], "")

  depends_on = [module.cicd_bootstrap]
}

resource "github_actions_environment_secret" "tenant_id" {
  repository      = var.github_repo
  environment     = var.github_environment
  secret_name     = "AZURE_TENANT_ID"
  plaintext_value = module.cicd_bootstrap.tenant_id

  depends_on = [module.cicd_bootstrap]
}

resource "github_actions_environment_secret" "kv_name" {
  repository      = var.github_repo
  environment     = var.github_environment
  secret_name     = "BOOTSTRAP_KV_NAME"
  plaintext_value = var.bootstrap_keyvault_name

  depends_on = [azurerm_key_vault.bootstrap]
}
