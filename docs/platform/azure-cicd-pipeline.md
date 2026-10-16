# Azure Bootstrap — CI/CD Pipeline

> Last updated: 2026-10-16 (updated: Terraform provider cache, pull_request OIDC)

---

## Trigger → Job Matrix

```
Event                          setup  validate  plan/{env}  apply/{env}  destroy/{env}
─────────────────────────────  ─────  ────────  ──────────  ───────────  ────────────
pull_request (bootstrap/**)     ✓       ✓          ✓            –             –
push main (bootstrap/**)        ✓       ✓          ✓            ✓             –
dispatch action=plan            ✓       ✓          ✓            –             –
dispatch action=apply           ✓       ✓          ✓            ✓             –
dispatch action=destroy         ✓       ✓          ✓            –             ✓
schedule 02:00 UTC (drift)      ✓       –          ✓            –             –
```

### Apply gating per environment

| Env | GitHub environment | Approval | Wait |
|---|---|---|---|
| dev | `bootstrap-dev` | không cần | 0 min |
| test | `bootstrap-test` | không cần | 2 min |
| stg | `bootstrap-stg` | ✓ required | 5 min |
| prod | `bootstrap-prod` | ✓ required | 10 min |

---

## Job dependency chain

```
setup ─────────────────────────────────────────────────────────┐
(detect changed envs via paths-filter)                          │
  ↓ has_envs=true                                              │
validate (needs: setup)                                         │
(terraform fmt, validate, tflint, OPA, checkov, trivy)         │
  ↓ success                                                     ↓
plan/dev  plan/test  plan/stg  plan/prod  (needs: [setup, validate], matrix)
  ↓           ↓          ↓         ↓     (parallel, per-env state key)
apply/dev apply/test apply/stg apply/prod (needs: [setup, plan], matrix)
[no gate] [2min]    [approval] [approval+10min]
```

---

## Environment detection (setup job)

Uses `dorny/paths-filter@v4.0.3` (SHA-pinned):

| Files changed | Environments |
|---|---|
| `envs/dev.tfvars` | `[dev]` |
| `envs/test.tfvars` | `[test]` |
| `main.tf`, `*.tf` (shared code) | `[dev, test, stg, prod]` |
| Manual dispatch `environments=dev,test` | `[dev, test]` |
| Manual dispatch `environments=all` | `[dev, test, stg, prod]` |
| Schedule (drift detection) | `[dev, test, stg, prod]` |
| No bootstrap files changed | `[]` → all jobs skipped |

---

## Terraform state per environment

```
Azure Blob Storage (stplatformtfstate<hex>):
  tfstate/
    bootstrap/dev/terraform.tfstate
    bootstrap/test/terraform.tfstate
    bootstrap/stg/terraform.tfstate
    bootstrap/prod/terraform.tfstate
```

---

## Concurrency control

```yaml
# Workflow level — prevents overlapping runs per ref
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true for PR/plan, false for push/apply/destroy

# Per-env level — prevents parallel apply to same env
concurrency:
  group: ${{ github.workflow }}-${{ matrix.env }}-apply-${{ github.ref }}
  cancel-in-progress: false  # NEVER cancel apply (state corruption)
```

---

## Required GitHub secrets & variables

### Secrets (repo-level)

| Secret | Dùng ở | Mô tả |
|---|---|---|
| `AZURE_BOOTSTRAP_CLIENT_ID` | bootstrap workflow | Init UAMI client ID (set bởi init.sh) |
| `AZURE_READONLY_CLIENT_ID` | plan jobs | Read-only UAMI (optional, fallback to bootstrap) |
| `AZURE_TENANT_ID` | cả hai workflow | Azure Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | bootstrap workflow | Azure subscription ID |
| `GH_PAT` | bootstrap workflow | GitHub PAT (read:org + repo, cho AVM module) |
| `PLATFORM_DOMAIN` | bootstrap workflow | Platform ingress domain |
| `INFRACOST_API_KEY` | plan job (optional) | Infracost cost estimation |

### Variables (repo-level)

| Variable | Value | Mô tả |
|---|---|---|
| `AZURE_LOCATION` | `southeastasia` | Azure region |
| `HUB_RESOURCE_GROUP` | `rg-peeks-hub-azure` | Hub AKS resource group |
| `HUB_CLUSTER_NAME` | `peeks-hub-azure` | Hub AKS cluster name |
| `BOOTSTRAP_KV_NAME` | `kv-peeks-bootstrap` | Bootstrap Key Vault name |
| `ACR_NAME` | `peeksplatformsea` | Azure Container Registry name |
| `LOCATION_SHORT` | `sea` | AVM location abbreviation |
| `TF_BACKEND_RESOURCE_GROUP` | `rg-platform-bootstrap-init` | TF state storage RG |
| `TF_BACKEND_STORAGE_ACCOUNT` | `stplatformtfstate<hex>` | TF state storage account |

### Secrets (environment-level: azure-hub)

Set bởi Bootstrap Terraform (Giai đoạn 2):

| Secret | Mô tả |
|---|---|
| `AZURE_CLIENT_ID` | Platform UAMI client ID |
| `AZURE_TENANT_ID` | Azure tenant ID |
| `BOOTSTRAP_KV_NAME` | Bootstrap Key Vault name |

---

## Artifact management

- `tfplan-{env}-{sha}` — Terraform plan artifact per env, retention 7 days
- Apply downloads EXACT plan từ plan job → zero drift giữa plan và apply

---

## Terraform provider cache

Workflow dùng `TF_PLUGIN_CACHE_DIR` để cache providers giữa các steps trong cùng job:

```yaml
env:
  TF_PLUGIN_CACHE_DIR: ${{ github.workspace }}/.terraform.d/plugin-cache

steps:
  - name: Cache Terraform providers
    uses: actions/cache@v6.1.0  # SHA-pinned: 55cc8345...
    with:
      path: ${{ env.TF_PLUGIN_CACHE_DIR }}
      key: ${{ runner.os }}-terraform-${{ hashFiles('**/.terraform.lock.hcl') }}
      restore-keys: |
        ${{ runner.os }}-terraform-
```

Cache key dựa trên `.terraform.lock.hcl` — thay đổi provider version tự động invalidate cache.

---

## OIDC federated credentials

Workflow dùng Azure OIDC (không có static secrets). Init UAMI cần 3 federated credentials:

| Name | Subject | Dùng ở |
|---|---|---|
| `github-bootstrap-env` | `repo:<org>@<orgId>/<repo>@<repoId>:environment:bootstrap` | apply / destroy jobs |
| `github-main-branch` | `repo:<org>@<orgId>/<repo>@<repoId>:ref:refs/heads/main` | push-to-main plan |
| `github-pull-request` | `repo:<org>@<orgId>/<repo>@<repoId>:pull_request` | PR plan (read-only) |

> **Immutable format**: GitHub dùng numeric node IDs (`@<orgId>`, `@<repoId>`) từ July 2026.
> Subject phải khớp chính xác với claim trong JWT — lấy exact subject từ error message nếu cần.

Thêm federated credential thủ công (nếu thiếu):
```bash
az identity federated-credential create \
  --identity-name "platform-bootstrap-init-mi" \
  --resource-group "rg-platform-bootstrap-init" \
  --name "github-pull-request" \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "repo:<org>@<orgId>/<repo>@<repoId>:pull_request" \
  --audiences "api://AzureADTokenExchange"
```

---

## Liên quan

- `docs/platform/azure-bootstrap-deploy.md` — Full setup guide
- `docs/platform/azure-multienv-terraform.md` — Multi-env design
- `docs/platform/azure-pre-commit-hooks.md` — Pre-commit hooks
