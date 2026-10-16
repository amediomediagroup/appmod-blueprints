# Azure Bootstrap — Setup & Deploy Guide

> Provider: `kind-crossplane-azure`
> Last updated: 2026-10-16

Hướng dẫn deploy platform lên Azure từ đầu đến cuối.

---

## Tổng quan luồng

```
Giai đoạn 1 — Init (local, 1 lần)
  scripts/init.sh
    → TF state storage (Azure Blob)
    → Init UAMI + federated credentials (environment:bootstrap + ref:main)
    → GitHub secrets: AZURE_BOOTSTRAP_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID
    → GitHub vars: TF_BACKEND_RESOURCE_GROUP, TF_BACKEND_STORAGE_ACCOUNT

Giai đoạn 2 — Bootstrap (GitHub Actions: bootstrap-azure.yml)
  Terraform apply (AVM modules)
    → Platform UAMI (write identity)
    → Bootstrap Key Vault + platform-config secret
    → Hub Resource Group
    → Azure Container Registry (Premium, RBAC-only)
    → GitHub environment azure-hub + secrets

Giai đoạn 3 — Deploy (GitHub Actions: deploy-azure-hub.yml)
  task kind-crossplane-azure:install
    → Kind cluster (bootstrap)
    → Crossplane + Azure providers
    → AKS cluster + addons via Crossplane
    → ArgoCD sync
```

---

## Cài đặt tools

```bash
# macOS — cài tất cả
brew install azure-cli gh kubectl helm kind yq jq go-task/tap/go-task pre-commit

# Xác nhận
az version && gh version && task --version
```

---

## Giai đoạn 1 — Init (local, 1 lần)

### Prerequisites

- `az login` — account cần **Contributor + User Access Administrator** trên subscription
- `gh auth login`
- CLIs: `az`, `gh`, `openssl`

### Chạy init.sh

```bash
export SUBSCRIPTION_ID="<azure-subscription-id>"
export GITHUB_ORG="<github-org>"
export GITHUB_REPO="appmod-blueprints"
export LOCATION="southeastasia"

bash cluster-providers/kind-crossplane-azure/bootstrap/scripts/init.sh
```

Script tạo ra:

| Resource | Mô tả |
|---|---|
| RG `rg-platform-bootstrap-init` | Chứa init resources |
| Storage account `stplatformtfstate<6-hex>` | Terraform state backend |
| Init UAMI `platform-bootstrap-init-mi` | Identity cho bootstrap workflow |
| Federated credential (2) | `environment:bootstrap` + `ref:refs/heads/main` (immutable subject format) |
| GitHub secrets (3) | `AZURE_BOOTSTRAP_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` |
| GitHub vars (2) | `TF_BACKEND_RESOURCE_GROUP`, `TF_BACKEND_STORAGE_ACCOUNT` |
| `backend.conf` (local) | Backend config cho Terraform, gitignored |

### Tạo GitHub environment `bootstrap`

```bash
USER_ID=$(gh api /user --jq '.id')

gh api -X PUT repos/<org>/appmod-blueprints/environments/bootstrap \
  --field "reviewers[][type]=User" \
  --field "reviewers[][id]=$USER_ID" \
  --field "wait_timer=5" \
  --field "prevent_self_review=true"
```

### Set GitHub variables & secrets

```bash
ORG="<org>"
REPO="appmod-blueprints"

# Non-sensitive vars
gh variable set AZURE_LOCATION       --repo $ORG/$REPO --body "southeastasia"
gh variable set HUB_RESOURCE_GROUP   --repo $ORG/$REPO --body "rg-peeks-hub-azure"
gh variable set HUB_CLUSTER_NAME     --repo $ORG/$REPO --body "peeks-hub-azure"
gh variable set BOOTSTRAP_KV_NAME    --repo $ORG/$REPO --body "kv-peeks-bootstrap"
gh variable set ACR_NAME             --repo $ORG/$REPO --body "peeksplatformsea"
gh variable set LOCATION_SHORT       --repo $ORG/$REPO --body "sea"

# Sensitive secrets
gh secret set PLATFORM_DOMAIN --repo $ORG/$REPO --body "<domain>"
gh secret set GH_PAT          --repo $ORG/$REPO --body "<token-with-read:org+repo>"
```

> `GH_PAT` cần scopes: `read:org`, `repo` (cho AVM module đọc GitHub org + tạo environments).
> `GITHUB_ORG` và `GITHUB_REPO` không thể đặt làm variable (reserved) → workflow dùng `github.repository_owner`.

### Tạo terraform.tfvars

```bash
cd cluster-providers/kind-crossplane-azure/bootstrap
cp terraform.tfvars.example terraform.tfvars
# Điền các giá trị — file này gitignored, không commit
```

---

## Giai đoạn 2 — Bootstrap (GitHub Actions)

Workflow: **Bootstrap Azure Platform** (`.github/workflows/bootstrap-azure.yml`)

Xem pipeline chi tiết tại: `docs/platform/azure-cicd-pipeline.md`

### Chạy plan trước

```
GitHub Actions → Bootstrap Azure Platform → Run workflow
  environments: all
  action: plan
```

### Apply

```
GitHub Actions → Bootstrap Azure Platform → Run workflow
  environments: all
  action: apply
```

> Apply được gated bởi `environment:bootstrap` — cần reviewer approve + đợi 5 phút.

Sau bootstrap, revoke elevated roles của init UAMI:

```bash
INIT_ID=$(az identity show \
  --name platform-bootstrap-init-mi \
  --resource-group rg-platform-bootstrap-init \
  --query principalId -o tsv)

az role assignment delete --assignee "$INIT_ID" \
  --role "Contributor" --scope "/subscriptions/$SUBSCRIPTION_ID"
az role assignment delete --assignee "$INIT_ID" \
  --role "User Access Administrator" --scope "/subscriptions/$SUBSCRIPTION_ID"
```

---

## Giai đoạn 3 — Deploy platform (GitHub Actions)

Workflow: **Deploy Azure Hub** (`.github/workflows/deploy-azure-hub.yml`)

```
GitHub Actions → Deploy Azure Hub → Run workflow
  hub_cluster_name: peeks-hub-azure
  kubernetes_version: 1.37
  action: install
```

| Action | Mô tả | Gate |
|---|---|---|
| `install` | Provision AKS + bootstrap (idempotent) | environment:azure-hub |
| `status` | Show cluster status | environment:azure-hub |
| `destroy-kind` | Xóa Kind cluster (AKS giữ nguyên) | environment:azure-hub |
| `destroy` | ⚠️ Full teardown | environment:azure-hub-destroy (10min) |

Workflow đọc toàn bộ config từ Bootstrap Key Vault — zero PII trong code.

---

## Teardown

```
# Xóa bootstrap Terraform resources
GitHub Actions → Bootstrap Azure Platform → action: destroy

# Xóa init resources (manual)
az group delete --name rg-platform-bootstrap-init --yes
```

---

## Liên quan

- `docs/platform/azure-cicd-pipeline.md` — Chi tiết CI/CD pipeline
- `docs/platform/azure-multienv-terraform.md` — Multi-environment design
- `docs/platform/azure-image-security.md` — ACR + Cosign
- `docs/platform/azure-pre-commit-hooks.md` — Pre-commit hooks
