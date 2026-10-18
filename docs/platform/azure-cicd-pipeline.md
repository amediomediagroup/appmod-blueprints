# Azure Bootstrap — CI/CD Pipeline

> Last updated: 2026-10-17 (security hardening: credential-less PRs, per-env
> trust isolation, sealed env/SHA/mode-bound plans, OPA across all packages)

---

## Trigger → Job matrix

```
Event                         setup  validate  pr-check  plan  apply  destroy  drift
────────────────────────────  ─────  ────────  ────────  ────  ─────  ───────  ─────
pull_request (bootstrap/**)     ✓       ✓          ✓       –      –       –       –
push main (bootstrap/**)        ✓       ✓          –       ✓      ✓       –       –
dispatch action=plan            ✓       ✓          –       ✓      –       –       –
dispatch action=apply           ✓       ✓          –       ✓      ✓       –       –
dispatch action=destroy         ✓       ✓          –       ✓      –       ✓       –
schedule 02:00 UTC (drift)      ✓       –          –       –      –       –       ✓
```

---

## Security model

The pipeline draws a hard trust boundary between **untrusted** events
(pull requests, including forks) and **trusted** events (protected `main`
pushes and `workflow_dispatch`, which only write-access users can trigger).

### Pull requests are credential-less

A pull request — even from a fork — runs **only** the `validate` and
`pr-check` jobs. These jobs:

- never call `azure/login` and never request an OIDC `id-token`,
- never mint a GitHub App token,
- never run an authenticated `terraform plan` against real state,
- never upload a plan artifact,
- post only an **offline** PR comment (default `GITHUB_TOKEN`) that states
  explicitly that no cloud credentials were used.

There is no OIDC federation for `pull_request` and no fallback to a bootstrap
identity. A fork PR therefore cannot obtain Azure or GitHub-write credentials
and cannot produce a plan that `apply` would trust.

### Authenticated plan runs only on trusted events

`setup` computes a `trusted` output that is `true` only for a protected `main`
push or a `workflow_dispatch`. The `plan` job gates on `trusted == 'true'`, so
an authenticated plan never runs for a pull request.

### Per-environment identity isolation

| Deployment environment | Identity | Azure role | GitHub App token |
|---|---|---|---|
| `bootstrap-plan-{env}` | read-only plan UAMI (`AZURE_CLIENT_ID`) | Reader + state/KV read | **read-only** (contents:read, metadata:read), this repo only |
| `bootstrap-{env}` | write apply UAMI (`AZURE_CLIENT_ID`) | Contributor + User Access Administrator | **write**, this repo only |

Each environment holds its **own** `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
`AZURE_SUBSCRIPTION_ID` and `PLAN_ENCRYPTION_KEY`. There are no shared global
`TF_VAR_*` secrets; every per-env resource var and secret is resolved inside
the environment-scoped job.

### Apply gating per environment

| Env | Deployment environment | Approval | Wait |
|---|---|---|---|
| dev | `bootstrap-dev` | none | 0 min |
| test | `bootstrap-test` | none | 2 min |
| stg | `bootstrap-stg` | ✓ required reviewer | 5 min |
| prod | `bootstrap-prod` | ✓ required reviewer | 10 min |

Configure the approval/wait protections in **repo → Settings → Environments**.

---

## Job dependency chain

```
setup ────────────────────────────────────────────────┐
(resolve matrix + trusted flag — credential-less)      │
  ↓ has_envs=true                                      │
validate (needs: setup)                                │  pr-check (needs: setup, validate)
(fmt, init -lockfile=readonly, validate, tflint,       │  (offline PR comment, pull_request only)
 opa check, terraform test, Checkov, Trivy — strict)   │
  ↓ success  AND  setup.trusted == 'true'              ↓
plan/{dev,test,stg,prod}  (needs: [setup, validate], matrix, per-env OIDC)
  ↓ exitcode=2 (changes)   environment: bootstrap-plan-{env}
apply/{env}   or   destroy/{env}   (needs: [setup, plan], matrix)
environment: bootstrap-{env}        (consume sealed, bound, same-run plan)
```

Drift runs independently on `schedule` using the read-only
`bootstrap-plan-{env}` identity and never produces an artifact.

---

## Saved plan — bind, seal, verify

A saved Terraform plan is the only thing `apply` / `destroy` ever execute, and
it must be the exact plan produced earlier in the **same run**. The trust
boundary is enforced by `scripts/ci/terraform_plan_guard.py`:

1. **`plan`** runs `terraform plan -detailed-exitcode` (and `-destroy` for a
   destroy dispatch), producing `tfplan`.
2. **`bind`** writes an HMAC-signed manifest recording `environment`, `sha`,
   `mode` (`apply`|`destroy`), `run_id`, `run_attempt` and a UTC timestamp,
   plus the SHA-256 of the plan bytes.
3. **`seal`** AES-GCM-encrypts the plan + manifest into `tfplan.sealed` using a
   key derived from the per-env `PLAN_ENCRYPTION_KEY`, with the environment as
   authenticated associated data. The plan is encrypted **at rest** while it
   crosses jobs; cleartext plan bytes never appear in the artifact.
4. **`apply` / `destroy`** download the sealed artifact and run **`open`**,
   which verifies the AEAD, the manifest HMAC, and that the plan's
   `environment` / `sha` / `mode` match the consuming job and that the plan is
   within the freshness window — otherwise it is a hard failure.

- Artifact name: `tfplan-{mode}-{env}-{run_id}-{run_attempt}`.
- Retention: **1 day** (consumed within the same run).
- No artifact is uploaded for plan-only dispatch, PR checks, or drift.

The `-detailed-exitcode` contract: `0` = no changes, `1` = error, `2` =
changes. `apply` / `destroy` run only when `plan` reported `exitcode == 2`.

---

## OPA policy evaluation

`terraform_plan_guard.py opa` discovers **every** `package` under `policies/`
and evaluates each package's `deny` rule against the exact `terraform show
-json` output of the saved plan, failing on any decision. Package discovery is
dynamic, so adding a new package (e.g. a new `policies/*.rego`) is enforced
automatically. The current packages are:

| Package | File | Enforces |
|---|---|---|
| `terraform.azure.tagging` | `tagging.rego` | required tags on taggable resources |
| `terraform.azure.naming` | `naming.rego` | rg-/kv-/st prefixes, lowercase names |
| `terraform.azure.storage` | `storage.rego` | TLS 1.2, no public blob access |
| `terraform.azure.keyvault` | `key_vault.rego` | RBAC auth, soft-delete, secret metadata |
| `terraform.azure.iam` | `iam.rego` | no Owner role, principal_type required |

`validate` additionally runs `opa check policies/` for syntax on every PR.

---

## Terraform state per environment

```
Azure Blob Storage (TF_BACKEND_STORAGE_ACCOUNT):
  tfstate/
    bootstrap/dev/terraform.tfstate
    bootstrap/test/terraform.tfstate
    bootstrap/stg/terraform.tfstate
    bootstrap/prod/terraform.tfstate
```

All `terraform init` calls use `-lockfile=readonly`, so CI never regenerates
or fabricates the provider lockfile; a lockfile that does not satisfy the
configured providers fails the job. `validate` also fails fast if
`.terraform.lock.hcl` is missing.

---

## Concurrency control

A single non-cancellable group spans the **entire** plan → apply/destroy
lifecycle per environment and ref:

```yaml
concurrency:
  group: bootstrap-lifecycle-${{ matrix.env }}-${{ github.ref }}
  cancel-in-progress: false
```

- `apply` / `destroy` can **never** be cancelled by a new push or plan.
- `apply` and `destroy` for the same env serialize (shared group).
- Drift shares the group, so a scheduled drift plan can never cancel an
  in-flight apply.

---

## Environment credentials contract

Set the following on **each** deployment environment (`bootstrap-plan-{env}`
and `bootstrap-{env}`):

### Secrets

| Secret | Used by | Notes |
|---|---|---|
| `AZURE_CLIENT_ID` | plan / apply / destroy / drift | per-env UAMI (read-only for plan env, write for apply env) |
| `AZURE_TENANT_ID` | all authenticated jobs | Azure Entra tenant |
| `AZURE_SUBSCRIPTION_ID` | all authenticated jobs | per-env subscription |
| `PLAN_ENCRYPTION_KEY` | plan (seal) + apply/destroy (open) | per-env key; must match across the env's plan and apply environments |
| `GH_APP_ID`, `GH_APP_PRIVATE_KEY` | plan (read) / apply/destroy (write) | GitHub App scoped to this repository |
| `PLATFORM_DOMAIN` | all authenticated jobs | platform ingress domain |
| `INFRACOST_API_KEY` | plan (optional) | cost estimation |

### Variables

| Variable | Example | Notes |
|---|---|---|
| `AZURE_LOCATION` | `southeastasia` | per-env region |
| `HUB_RESOURCE_GROUP` | `rg-peeks-hub-dev` | per-env hub RG |
| `HUB_CLUSTER_NAME` | `peeks-hub-dev` | per-env hub AKS |
| `BOOTSTRAP_KV_NAME` | `kv-peeks-bootstrap-dev` | per-env Key Vault |
| `ACR_NAME` | `peeksplatformsea` | ACR name |
| `LOCATION_SHORT` | `sea` | AVM location abbreviation |
| `TF_BACKEND_RESOURCE_GROUP` | `rg-platform-bootstrap-init` | state storage RG |
| `TF_BACKEND_STORAGE_ACCOUNT` | `stplatformtfstate<hex>` | state storage account |

---

## Pinned tool versions

| Tool | Version | Pin |
|---|---|---|
| Terraform | `~1.11` | `TERRAFORM_VERSION` env |
| TFLint | `v0.59.1` | explicit (no `latest`) |
| OPA | `v1.9.0` | explicit (no `latest`) |
| `cryptography` (plan seal/open) | `46.0.7` | pinned (CVEs in <46.0.7 patched) |

Action SHAs are preserved from the previous workflow and reused across the
repo (checkout, cache, setup-terraform, azure/login, create-github-app-token,
upload/download-artifact, github-script, Checkov, Trivy, codeql upload-sarif,
Infracost).

---

## Drift detection

The scheduled `drift` job runs the read-only per-env plan with
`-detailed-exitcode` and, on `exitcode == 2`, opens **one** deduplicated issue
per environment (matched by a hidden `<!-- drift:bootstrap:{env} -->` marker);
a subsequent run comments on the existing issue instead of opening a duplicate.
It never uploads a plan artifact.

---

## Liên quan

- `cluster-providers/kind-crossplane-azure/bootstrap/` — Terraform source
- `scripts/ci/terraform_plan_guard.py` — plan bind/seal/open + OPA evaluation
- `scripts/tests/test_terraform_workflow.py` — plan-guard regression tests
- `docs/platform/azure-bootstrap-deploy.md` — Full setup guide
- `docs/platform/azure-multienv-terraform.md` — Multi-env design
