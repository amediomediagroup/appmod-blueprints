# Azure Bootstrap — Deployment Guide

> Provider: `kind-crossplane-azure`
> Last updated: 2026-10-16

Hướng dẫn deploy platform lên Azure từ đầu đến cuối, từ zero đến AKS cluster chạy ArgoCD + Crossplane.

---

## Tổng quan luồng

```
local: scripts/init.sh
    ↓  tạo init UAMI + TF state storage + 3 GitHub secrets
GitHub Actions: bootstrap-azure.yml  (environment: bootstrap)
    ↓  Terraform apply — dùng init UAMI (OIDC)
    ↓  tạo platform UAMI + Bootstrap Key Vault + hub resource group
GitHub Actions: deploy-azure-hub.yml  (environment: azure-hub)
    ↓  task install — dùng platform UAMI (OIDC)
    ↓  AKS + ArgoCD EKS Capability + Crossplane + addons
```

Có 3 giai đoạn: **Init** (local, một lần duy nhất) → **Bootstrap** (GitHub Actions) → **Deploy** (GitHub Actions).

---

## Cài đặt tools

### Bootstrap init (Giai đoạn 1 — local)

| Tool | Cài đặt |
|---|---|
| Azure CLI | `brew install azure-cli` |
| GitHub CLI | `brew install gh` |
| `openssl` | Pre-installed trên macOS/Linux |

```bash
# macOS
brew install azure-cli gh

# Ubuntu/Debian
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
sudo apt install gh

# Xác nhận
az version
gh version
```

### Deploy platform (Giai đoạn 3 — local hoặc CI)

| Tool | Cài đặt |
|---|---|
| `az` | Như trên |
| `kubectl` | `brew install kubectl` |
| `helm` | `brew install helm` |
| `kind` | `brew install kind` |
| `yq` | `brew install yq` |
| `jq` | `brew install jq` |
| `python3` | Pre-installed trên macOS; `brew install python@3` nếu thiếu |
| `task` | `brew install go-task/tap/go-task` |

```bash
# macOS — cài tất cả cùng lúc
brew install azure-cli gh kubectl helm kind yq jq go-task/tap/go-task

# Xác nhận
task --version
kind version
helm version --short
```

---



### Prerequisites

- `az login` với account có **Contributor + User Access Administrator** trên subscription
- `gh auth login`
- CLIs: `az`, `gh`

### Chạy init.sh

```bash
export SUBSCRIPTION_ID="<azure-subscription-id>"
export GITHUB_ORG="<github-org>"
export GITHUB_REPO="appmod-blueprints"
export LOCATION="southeastasia"       # hoặc region khác

bash cluster-providers/kind-crossplane-azure/bootstrap/scripts/init.sh
```

Script tạo ra:

| Resource | Mục đích |
|---|---|
| Resource group `rg-platform-bootstrap-init` | Chứa init resources |
| Storage account `stplatformtfstate<6-hex>` | Terraform state backend (tên tối đa 24 chars) |
| Init UAMI `platform-bootstrap-init-mi` | Identity cho bootstrap workflow |
| Federated credential | OIDC trust (2 credentials): `environment:bootstrap` (apply/destroy) + `ref:refs/heads/main` (validate on push) — immutable subject format |
| GitHub secrets (3) | `AZURE_BOOTSTRAP_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` |
| `backend.conf` (local) | Backend config cho Terraform, gitignored |

### Tạo GitHub environment `bootstrap`

```bash
# Tạo environment với protection rules
gh api -X PUT repos/<org>/appmod-blueprints/environments/bootstrap \
  --field "reviewers[][type]=User" \
  --field "reviewers[][id]=<your-github-user-id>" \
  --field "wait_timer=5" \
  --field "prevent_self_review=true"

# Lấy user ID của bạn
gh api /user --jq '.id'
```

Protection rules được cấu hình:
- **Required reviewer** — phải approve trước khi workflow chạy apply/destroy
- **Wait timer** — 5 phút delay để có thể cancel nếu trigger nhầm
- **Prevent self-review** — reviewer không thể tự approve workflow của mình

### Tạo terraform.tfvars

```bash
cd cluster-providers/kind-crossplane-azure/bootstrap
cp terraform.tfvars.example terraform.tfvars
# Điền các giá trị — file này gitignored, không commit
```

Các giá trị sensitive (`subscription_id`, `tenant_id`, `platform_domain`) **không cần** điền vào file — chúng được truyền qua `TF_VAR_*` env vars trong CI.

---

## Giai đoạn 2 — Bootstrap (GitHub Actions)

Workflow: **Bootstrap Azure Platform** (`.github/workflows/bootstrap-azure.yml`)

Trước khi chạy workflow, set các GitHub repository variables và secrets:

```bash
# Repository variables (non-sensitive)
gh variable set AZURE_LOCATION       --repo <org>/appmod-blueprints --body "southeastasia"
gh variable set HUB_RESOURCE_GROUP   --repo <org>/appmod-blueprints --body "rg-peeks-hub-azure"
gh variable set HUB_CLUSTER_NAME     --repo <org>/appmod-blueprints --body "peeks-hub-azure"
gh variable set BOOTSTRAP_KV_NAME    --repo <org>/appmod-blueprints --body "kv-peeks-bootstrap"
gh variable set LOCATION_SHORT       --repo <org>/appmod-blueprints --body "sea"

# Secrets (sensitive)
gh secret set PLATFORM_DOMAIN --repo <org>/appmod-blueprints --body "<domain>"

# GH_PAT — GitHub Personal Access Token với scopes: read:org, repo
# Cần để AVM module đọc org info + tạo GitHub environments
# Tạo tại: https://github.com/settings/tokens
gh secret set GH_PAT --repo <org>/appmod-blueprints --body "<token>"
```

> Note: `GITHUB_ORG`, `GITHUB_REPO`, `GITHUB_PAT` không thể đặt làm repo variable/secret (tên reserved).
> Workflow tự lấy org/repo từ `github.repository_owner` và `github.event.repository.name`.
> `GH_PAT` thay thế `GITHUB_TOKEN` cho Terraform github provider (cần `read:org` scope).

```
GitHub Actions → Run workflow → action: plan
```

Sau khi review plan output, chạy apply:

```
GitHub Actions → Run workflow → action: apply
```

Workflow tạo ra (qua Terraform + AVM module):

| Resource | Mục đích |
|---|---|
| GitHub environment `azure-hub` | Environment cho deploy workflow |
| Platform UAMI (write identity) | Identity cho ongoing operations |
| Federated credential | OIDC trust với GitHub environment `azure-hub` |
| Bootstrap Key Vault | Lưu toàn bộ platform config (zero PII trong code) |
| Secret `platform-config` trong KV | subscriptionId, tenantId, location, domain, repoUrl, ... |
| Hub resource group | RG nơi AKS cluster sẽ được tạo |
| GitHub secrets trong `azure-hub` env (3) | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `BOOTSTRAP_KV_NAME` |

Sau bước này, init UAMI không còn cần thiết. Nên revoke:

```bash
# Lấy principal ID của init UAMI
INIT_UAMI_PRINCIPAL_ID=$(az identity show \
  --name platform-bootstrap-init-mi \
  --resource-group rg-platform-bootstrap-init \
  --query principalId -o tsv)

az role assignment delete \
  --assignee "$INIT_UAMI_PRINCIPAL_ID" \
  --role "Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID"

az role assignment delete \
  --assignee "$INIT_UAMI_PRINCIPAL_ID" \
  --role "User Access Administrator" \
  --scope "/subscriptions/$SUBSCRIPTION_ID"
```

---

## Giai đoạn 3 — Deploy platform (GitHub Actions)

Workflow: **Deploy Azure Hub** (`.github/workflows/deploy-azure-hub.yml`)

Dùng `AZURE_CLIENT_ID` từ environment `azure-hub` (platform UAMI, tạo bởi bootstrap) để:

```
GitHub Actions → Run workflow
  hub_cluster_name: <tên AKS cluster>
  kubernetes_version: 1.37          (optional, default 1.37)
  action: install
```

Actions có sẵn:

| Action | Mô tả | Gate |
|---|---|---|
| `install` | Provision AKS + bootstrap platform (idempotent) | environment:azure-hub |
| `status` | Show cluster + ArgoCD sync status | environment:azure-hub |
| `destroy-kind` | Xóa local Kind cluster (AKS vẫn còn) | environment:azure-hub |
| `destroy` | ⚠️ Full teardown — xóa AKS + all resources | environment:azure-hub-destroy |

Environment gates:
- **`azure-hub`** — required reviewer + 5min wait
- **`azure-hub-destroy`** — required reviewer + **10min wait** (extra protection)

Workflow thực hiện:

1. Login Azure với OIDC (`azure-hub` platform UAMI — không có client secret)
2. Đọc toàn bộ config từ Bootstrap Key Vault (`platform-config` secret) — mask mọi giá trị sensitive
3. Build `config.local.yaml` từ env vars (zero PII trong file)
4. Chạy `task kind-crossplane-azure:<action>` (timeout 90 phút)
5. Post deploy summary lên GitHub Actions summary page

Concurrency: chỉ 1 deploy tại một thời điểm per cluster (`cancel-in-progress: false`).

Chỉ 3 GitHub secrets cần thiết (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `BOOTSTRAP_KV_NAME`) — tất cả đã được bootstrap Terraform tạo sẵn ở Giai đoạn 2.

---

## Teardown

Để xoá toàn bộ bootstrap infra:

```
GitHub Actions → Run workflow → action: destroy
```

Sau đó xoá thủ công init resources:

```bash
az group delete --name rg-platform-bootstrap-init --yes
```

---

## Liên quan

- `cluster-providers/kind-crossplane-azure/bootstrap/` — Terraform source
- `cluster-providers/kind-crossplane-azure/bootstrap/scripts/init.sh` — Init script
- `.github/workflows/bootstrap-azure.yml` — Bootstrap workflow
- `docs/platform/cluster-lifecycle.md` — Tổng quan cluster lifecycle
