# Azure Bootstrap — Multi-Environment Terraform Design

> Provider: `kind-crossplane-azure`
> Last updated: 2026-10-16
> Status: Implemented

---

## Vấn đề

Bootstrap Terraform hiện tại chỉ hỗ trợ một environment duy nhất. Khi cần deploy lên nhiều môi trường (dev, test, stg, prod), cần một cách quản lý có hệ thống, tránh duplicate code và đảm bảo mỗi env được isolate đúng cách.

---

## Quyết định: `-var-file` per environment

Ba pattern phổ biến:

| Pattern | Ưu | Nhược | Verdict |
|---|---|---|---|
| **`-var-file envs/{env}.tfvars`** | DRY code, simple state separation, dễ review diff | Sensitive vars vẫn cần secret management riêng | ✅ **Chọn** |
| Terraform Workspaces | Built-in, không cần file riêng | State mixing risk, workspace-aware code phức tạp | ❌ |
| Directory per environment | Maximum isolation | Code duplication, khó maintain | ❌ |

**Lý do chọn `-var-file`:**
- Cùng một Terraform code (`main.tf`, `variables.tf`) cho tất cả envs
- Mỗi env có file `.tfvars` riêng trong git (non-sensitive values only)
- State được tách bằng `key = "bootstrap/{env}/terraform.tfstate"`
- Sensitive values lấy từ GitHub environment-level secrets
- Dễ review: `git diff envs/dev.tfvars envs/prod.tfvars`

---

## Cấu trúc thư mục

```
cluster-providers/kind-crossplane-azure/bootstrap/
├── main.tf                   # Shared Terraform code (single source of truth)
├── variables.tf              # Variable declarations
├── versions.tf               # Provider + backend config
├── outputs.tf
├── policies/                 # OPA policies (shared)
└── envs/
    ├── dev.tfvars            # Dev-specific values (committed)
    ├── test.tfvars           # Test-specific values (committed)
    ├── stg.tfvars            # Staging-specific values (committed)
    └── prod.tfvars           # Prod-specific values (committed)
```

### Ví dụ `envs/dev.tfvars`

```hcl
# cluster-providers/kind-crossplane-azure/bootstrap/envs/dev.tfvars
# Non-sensitive env-specific overrides — committed to git
# Sensitive values (subscription_id, tenant_id, platform_domain) come from
# TF_VAR_* GitHub secrets — never put them here.
# Shared non-sensitive values come from TF_VAR_* GitHub vars (location, acr_name, etc.)

resource_name_environment = "dev"
github_environment        = "azure-hub"
repo_revision             = "main"
```

> Chỉ cần override những gì khác nhau giữa các envs. Giá trị shared đến từ `TF_VAR_*` GitHub vars.

### Ví dụ `envs/prod.tfvars`

```hcl
location                     = "southeastasia"
hub_resource_group           = "rg-peeks-hub-prod"
hub_cluster_name             = "peeks-hub-prod"
bootstrap_keyvault_name      = "kv-peeks-bootstrap-prod"
resource_prefix              = "prod"
resource_name_environment    = "prod"
resource_name_location_short = "sea"
resource_name_workload       = "plat"
github_environment           = "azure-hub-prod"
repo_revision                = "main"
```

---

## State isolation

Mỗi environment có state file riêng trên Azure Blob Storage:

```
tfstate container/
├── bootstrap/dev/terraform.tfstate
├── bootstrap/test/terraform.tfstate
├── bootstrap/stg/terraform.tfstate
└── bootstrap/prod/terraform.tfstate
```

Terraform init với state key per env:
```bash
terraform init \
  -backend-config="key=bootstrap/${ENV}/terraform.tfstate" \
  -backend-config="resource_group_name=${TF_BACKEND_RESOURCE_GROUP}" \
  -backend-config="storage_account_name=${TF_BACKEND_STORAGE_ACCOUNT}" \
  -backend-config="container_name=tfstate" \
  -backend-config="use_oidc=true"
```

---

## GitHub environment gates per tier

| Environment | GitHub env | Reviewer | Wait | Dùng cho |
|---|---|---|---|---|
| dev | `bootstrap-dev` | không cần | 0 min | Feature development |
| test | `bootstrap-test` | không cần | 2 min | Integration testing |
| stg | `bootstrap-stg` | ✓ required | 5 min | Pre-production validation |
| prod | `bootstrap-prod` | ✓ required | 10 min | Production |

Secrets được lưu ở **GitHub environment level** (không phải repo level):
- `bootstrap-dev` env: `AZURE_CLIENT_ID=<dev-uami-id>`, `AZURE_SUBSCRIPTION_ID=<dev-sub>`
- `bootstrap-prod` env: `AZURE_CLIENT_ID=<prod-uami-id>`, `AZURE_SUBSCRIPTION_ID=<prod-sub>`

---

## CI/CD workflow — parallel matrix

```yaml
# Simplified — full version in bootstrap-azure.yml
jobs:
  plan:
    strategy:
      matrix:
        env: [dev, test, stg, prod]
      fail-fast: false       # all envs plan in parallel, don't stop on first fail
    environment: bootstrap-${{ matrix.env }}
    concurrency:
      group: bootstrap-${{ matrix.env }}-${{ github.ref }}
      cancel-in-progress: true   # plan can be cancelled
    steps:
      - terraform init -backend-config="key=bootstrap/${{ matrix.env }}/terraform.tfstate" ...
      - terraform plan -var-file="envs/${{ matrix.env }}.tfvars" -out=tfplan

  apply:
    needs: plan
    strategy:
      matrix:
        env: [dev, test, stg, prod]
      fail-fast: false
    environment: bootstrap-${{ matrix.env }}   # gate per env
    concurrency:
      group: bootstrap-${{ matrix.env }}-apply-${{ github.ref }}
      cancel-in-progress: false   # NEVER cancel apply
    if: github.event_name == 'push' || github.event.inputs.action == 'apply'
```

### Promotion flow (push to main)

```
merge PR to main
      ↓ (parallel — all plan simultaneously)
  plan-dev  plan-test  plan-stg  plan-prod
      ↓ (each applies independently with its own gate)
  apply-dev     apply-test    apply-stg     apply-prod
  (no approval)  (2min wait)  (approval)   (approval + 10min)
```

---

## Selective environment deploy

Dùng `workflow_dispatch` với input để chọn env:

```
GitHub Actions → Run workflow
  environments: dev,test     ← chỉ deploy dev và test
  action: apply
```

Hoặc:
```
environments: all            ← deploy tất cả
environments: prod           ← chỉ prod
```

---

## Checklist triển khai

- [ ] Tạo `envs/dev.tfvars`, `test.tfvars`, `stg.tfvars`, `prod.tfvars`
- [ ] Tạo GitHub environments: `bootstrap-dev`, `bootstrap-test`, `bootstrap-stg`, `bootstrap-prod`
- [ ] Set secrets per GitHub environment (AZURE_CLIENT_ID, AZURE_SUBSCRIPTION_ID)
- [ ] Set backend vars per GitHub environment (TF_BACKEND_STORAGE_ACCOUNT nếu dùng separate SA)
- [ ] Chạy `init.sh` cho từng env (hoặc tạo UAMI per env)
- [ ] Cập nhật `bootstrap-azure.yml` với matrix strategy
- [ ] Verify plan clean trên dev trước khi enable auto-apply

---

## Liên quan

- `cluster-providers/kind-crossplane-azure/bootstrap/` — Terraform source
- `.github/workflows/bootstrap-azure.yml` — Bootstrap workflow
- `docs/platform/azure-bootstrap-deploy.md` — Deploy guide (Giai đoạn 1-3)
