# Azure Bootstrap — Pre-commit Hooks

> Last updated: 2026-10-16

---

## Setup

```bash
brew install pre-commit
cd appmod-blueprints

# Install commit hooks
pre-commit install                          # file hygiene + terraform + gitleaks
pre-commit install --hook-type commit-msg   # conventional commit message

# Test all hooks on changed files
pre-commit run --from-ref origin/main --to-ref HEAD
```

---

## Hooks

### Standard hooks (`pre-commit-hooks v6.0.0`)

| Hook | Mô tả |
|---|---|
| `trailing-whitespace` | Xóa trailing whitespace |
| `end-of-file-fixer` | Đảm bảo file kết thúc bằng newline |
| `check-yaml` | Validate YAML syntax |
| `check-json` | Validate JSON syntax |
| `check-merge-conflict` | Không commit merge conflict markers |
| `detect-private-key` | Phát hiện private keys |
| `check-added-large-files` | Block files > 1MB |
| `mixed-line-ending` | Enforce LF line endings |

### Secret detection (`gitleaks v8.30.1`)

Scan staged files cho secrets và API keys. No license required (CLI, not action).

Local: runs on staged files only.
CI: runs on PR commits only (`--log-opts=origin/main..HEAD`).

### Terraform (`pre-commit-terraform v1.109.2`)

| Hook | Mô tả | Scope |
|---|---|---|
| `terraform_fmt` | Auto-format `.tf` files | All |
| `terraform_validate` | Validate Terraform syntax | `bootstrap/` only |
| `terraform_tflint` | Terraform linter | `bootstrap/` only |

### Conventional Commits (`conventional-pre-commit v4.4.0`)

Validate commit message format: `<type>(<scope>): <description>`

Types: `feat`, `fix`, `docs`, `chore`, `refactor`, `perf`, `test`, `ci`, `build`, `revert`

```
feat(azure): add ACR AVM module
fix(ci): add TF_VAR_acr_name to workflow
docs(azure): write deployment guide
chore(deps): bump actions/checkout to v7.0.1
```

---

## Custom hooks (`local`)

### `check-action-sha-pins`

Kiểm tra tất cả GitHub Actions `uses:` được pinned tới full 40-char SHA.

```yaml
# ❌ FAIL — floating tag
uses: actions/checkout@v7

# ✅ PASS — SHA-pinned
uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
```

Để lấy SHA:
```bash
gh api repos/actions/checkout/git/ref/tags/v7.0.1 --jq '.object.sha'
```

### `check-avm-telemetry`

Kiểm tra tất cả AVM module blocks (`Azure/avm-*`) có `enable_telemetry = false`.

```hcl
# ❌ FAIL — telemetry có thể gửi data đến Microsoft
module "acr" {
  source = "Azure/avm-res-containerregistry-registry/azurerm"
  version = "0.8.0"
}

# ✅ PASS
module "acr" {
  source           = "Azure/avm-res-containerregistry-registry/azurerm"
  version          = "0.8.0"
  enable_telemetry = false
}
```

### `check-helm-stable`

Kiểm tra Helm chart versions không có pre-release suffix.

```yaml
# ❌ FAIL
version: 1.0.0-beta.1
defaultVersion: 'v2.0.0-rc.2'

# ✅ PASS
version: 1.0.0
defaultVersion: 'v2.0.0'
```

### `check-image-digest`

Kiểm tra container images dùng ACR + SHA digest.

```yaml
# ❌ FAIL — tag only
image: nginx:1.25.3

# ❌ FAIL — mutable tag
image: nginx:latest

# ⚠️ WARN — digest but not ACR
image: nginx@sha256:1a2b3c...

# ✅ PASS — ACR + digest
image: myacr.azurecr.io/nginx@sha256:1a2b3c...
```

---

## CI integration

`pr-lint.yml` chạy pre-commit trên PR diff:

```yaml
pre-commit run \
  --from-ref "origin/${{ github.base_ref }}" \
  --to-ref HEAD \
  --show-diff-on-failure
```

Gitleaks riêng, scan PR commits only:
```bash
gitleaks detect \
  --config=.gitleaks.toml \
  --log-opts="origin/main..HEAD" \
  --exit-code=1
```

---

## Liên quan

- `.pre-commit-config.yaml` — Hook configuration
- `.gitleaks.toml` — Gitleaks false-positive suppression
- `.pre-commit-hooks/` — Custom hook scripts
