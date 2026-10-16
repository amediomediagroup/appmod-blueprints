#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# init.sh — One-time pre-bootstrap setup
#
# Run ONCE locally before the bootstrap GitHub Actions workflow.
# Creates:
#   1. Storage account for Terraform state
#   2. Initial UAMI for bootstrap workflow to authenticate to Azure
#   3. Federated credential so bootstrap-azure.yml can login with OIDC
#   4. Sets 3 GitHub repo secrets (AZURE_BOOTSTRAP_CLIENT_ID, AZURE_TENANT_ID,
#      AZURE_SUBSCRIPTION_ID) needed by the bootstrap workflow
#
# Prerequisites:
#   az login  (with Contributor + User Access Administrator on target subscription)
#   gh auth login
#   Required CLIs: az, gh
#
# Usage:
#   export SUBSCRIPTION_ID="<id>"
#   export GITHUB_ORG="<org>"
#   export GITHUB_REPO="<repo>"
#   export LOCATION="<azure-region>"
#   bash scripts/init.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

: "${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID}"
: "${GITHUB_ORG:?Set GITHUB_ORG}"
: "${GITHUB_REPO:?Set GITHUB_REPO}"
: "${LOCATION:?Set LOCATION}"

BOOTSTRAP_RG="${BOOTSTRAP_RG:-rg-platform-bootstrap-init}"
TF_STATE_SA="${TF_STATE_SA:-stplatformtfstate$(openssl rand -hex 3)}"
TF_STATE_CONTAINER="tfstate"
INIT_UAMI_NAME="${INIT_UAMI_NAME:-platform-bootstrap-init-mi}"

echo "▸ Setting subscription context..."
az account set --subscription "$SUBSCRIPTION_ID"

TENANT_ID=$(az account show --query tenantId -o tsv)
echo "  Tenant ID: (masked)"

echo ""
echo "▸ Creating bootstrap resource group: $BOOTSTRAP_RG"
az group create \
  --name "$BOOTSTRAP_RG" \
  --location "$LOCATION" \
  --output none

echo ""
echo "▸ Creating Terraform state storage account: $TF_STATE_SA"
az storage account create \
  --name "$TF_STATE_SA" \
  --resource-group "$BOOTSTRAP_RG" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --output none

az storage container create \
  --name "$TF_STATE_CONTAINER" \
  --account-name "$TF_STATE_SA" \
  --output none

echo "  Storage account created: $TF_STATE_SA"

echo ""
echo "▸ Creating initial bootstrap UAMI: $INIT_UAMI_NAME"
az identity create \
  --name "$INIT_UAMI_NAME" \
  --resource-group "$BOOTSTRAP_RG" \
  --location "$LOCATION" \
  --output none

INIT_UAMI_CLIENT_ID=$(az identity show \
  --name "$INIT_UAMI_NAME" \
  --resource-group "$BOOTSTRAP_RG" \
  --query clientId -o tsv)

INIT_UAMI_PRINCIPAL_ID=$(az identity show \
  --name "$INIT_UAMI_NAME" \
  --resource-group "$BOOTSTRAP_RG" \
  --query principalId -o tsv)

echo "  UAMI created (client ID masked)"

echo ""
echo "▸ Granting bootstrap UAMI: Contributor + User Access Administrator on subscription"
# AVM module needs to create resource groups and role assignments.
# User Access Administrator is required to delegate permissions (create role assignments).
# Owner is overkill — use minimum viable permissions.
az role assignment create \
  --assignee-object-id "$INIT_UAMI_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID" \
  --output none

az role assignment create \
  --assignee-object-id "$INIT_UAMI_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "User Access Administrator" \
  --scope "/subscriptions/$SUBSCRIPTION_ID" \
  --output none

echo "  Roles assigned (Contributor + User Access Administrator)"

echo ""
echo "▸ Granting bootstrap UAMI: Storage Blob Data Contributor (for TF state)"
TF_SA_ID=$(az storage account show --name "$TF_STATE_SA" --resource-group "$BOOTSTRAP_RG" --query id -o tsv)
az role assignment create \
  --assignee-object-id "$INIT_UAMI_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "$TF_SA_ID" \
  --output none

echo "  Storage role assigned"

echo ""
echo "▸ Registering federated credential for bootstrap-azure.yml (environment: bootstrap)..."
# Security: environment-scoped subject restricts token to runs in 'bootstrap' environment
# The GitHub environment should have protection rules (optional reviewers)
az identity federated-credential create \
  --identity-name "$INIT_UAMI_NAME" \
  --resource-group "$BOOTSTRAP_RG" \
  --name "github-bootstrap-env" \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "repo:${GITHUB_ORG}/${GITHUB_REPO}:environment:bootstrap" \
  --audiences "api://AzureADTokenExchange" \
  --output none

echo "  Federated credential registered"

echo ""
echo "▸ Setting GitHub repo secrets for bootstrap workflow..."
gh secret set AZURE_BOOTSTRAP_CLIENT_ID \
  --repo "${GITHUB_ORG}/${GITHUB_REPO}" \
  --body "$INIT_UAMI_CLIENT_ID"

gh secret set AZURE_TENANT_ID \
  --repo "${GITHUB_ORG}/${GITHUB_REPO}" \
  --body "$TENANT_ID"

gh secret set AZURE_SUBSCRIPTION_ID \
  --repo "${GITHUB_ORG}/${GITHUB_REPO}" \
  --body "$SUBSCRIPTION_ID"

echo "  GitHub secrets set (3 secrets)"

echo ""
echo "▸ Writing backend config for CI..."
cat > "$(dirname "$0")/../backend.conf" << CONF
resource_group_name  = "$BOOTSTRAP_RG"
storage_account_name = "$TF_STATE_SA"
container_name       = "$TF_STATE_CONTAINER"
key                  = "bootstrap/terraform.tfstate"
use_oidc             = true
CONF

echo "  backend.conf written"
echo ""
echo "─────────────────────────────────────────────────────────────────────"
echo "✓ Init complete. Next steps:"
echo ""
echo "  1. Create GitHub environment 'bootstrap' with optional protection rules"
echo "     gh api -X PUT repos/${GITHUB_ORG}/${GITHUB_REPO}/environments/bootstrap"
echo ""
echo "  2. Push to main or run workflow 'Bootstrap Azure Platform' manually"
echo "     The workflow will use AZURE_BOOTSTRAP_CLIENT_ID to run Terraform."
echo ""
echo "  3. (Optional but recommended) After bootstrap completes, revoke the"
echo "     elevated roles from init UAMI:"
echo "     az role assignment delete --assignee $INIT_UAMI_PRINCIPAL_ID --role Contributor --scope /subscriptions/$SUBSCRIPTION_ID"
echo "     az role assignment delete --assignee $INIT_UAMI_PRINCIPAL_ID --role 'User Access Administrator' --scope /subscriptions/$SUBSCRIPTION_ID"
echo ""
echo "  The AVM module creates a dedicated platform UAMI for ongoing operations."
echo "─────────────────────────────────────────────────────────────────────"
