# Azure Bootstrap — CI/CD Pipeline

> Last updated: 2026-10-16

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

## Liên quan

- `docs/platform/azure-bootstrap-deploy.md` — Full setup guide
- `docs/platform/azure-multienv-terraform.md` — Multi-env design
- `docs/platform/azure-pre-commit-hooks.md` — Pre-commit hooks
