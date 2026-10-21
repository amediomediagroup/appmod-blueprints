# Azure Image Security — ACR + Cosign

> Provider: `kind-crossplane-azure`
> Last updated: 2026-10-17

---

## Policy

Tất cả container images dùng trong Kubernetes workloads phải:
1. **Được lưu trong ACR** (`*.azurecr.io`) — không dùng public registry trực tiếp
2. **Pinned to SHA digest** (`@sha256:<64hex>`) — không dùng mutable tag
3. **Được ký bằng Cosign** trước khi deploy

---

## Import image vào ACR

```bash
# Login ACR
az acr login --name <acr-name>

# Import từ public registry
az acr import \
  --name <acr-name> \
  --source nginx:1.25.3 \
  --image nginx:1.25.3

# Lấy digest sau khi import
DIGEST=$(az acr manifest list-metadata \
  --registry <acr-name> \
  --name nginx \
  --query "[?tags[?@=='1.25.3']].digest" \
  -o tsv)

echo "<acr-name>.azurecr.io/nginx@$DIGEST"
```

---

## Ký image với Cosign (keyless — GitHub OIDC)

```bash
# Install cosign
brew install cosign

# Sign image từ CI (GitHub Actions — keyless via OIDC)
cosign sign \
  --yes \
  <acr-name>.azurecr.io/nginx@sha256:<digest>

# Verify — dùng EXACT workflow identity, KHÔNG dùng regexp prefix.
# Signer identity là canonical workflow path@ref được lưu trong cert.
#
# Mirrored images (image-mirror.yml):
cosign verify \
  --certificate-identity="https://github.com/amediomediagroup/appmod-blueprints/.github/workflows/image-mirror.yml@refs/heads/main" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  <acr-name>.azurecr.io/<image>@sha256:<digest>

# First-party images (image-publish.yml):
cosign verify \
  --certificate-identity="https://github.com/amediomediagroup/appmod-blueprints/.github/workflows/image-publish.yml@refs/heads/main" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  <acr-name>.azurecr.io/<image>@sha256:<digest>
```

> **Lưu ý bảo mật:** `--certificate-identity` (exact match) được dùng thay vì
> `--certificate-identity-regexp` vì regexp chấp nhận bất kỳ workflow nào trong
> repo (kể cả PR từ fork). Exact identity chỉ tin tưởng đúng workflow file trên
> `refs/heads/main`.

---

## Trong Kubernetes manifests

```yaml
# ❌ Không dùng
image: nginx:1.25.3

# ✅ Đúng
image: myacr.azurecr.io/nginx@sha256:1a2b3c4d...

# ✅ Cũng đúng (tag + digest)
image: myacr.azurecr.io/nginx:1.25.3@sha256:1a2b3c4d...
```

---

## Pre-commit enforcement

`check-image-digest` hook trong `.pre-commit-config.yaml`:

| Trường hợp | Kết quả |
|---|---|
| `*.azurecr.io/image@sha256:...` | ✅ PASS |
| `*.azurecr.io/image:tag@sha256:...` | ✅ PASS |
| `*.azurecr.io/image:tag` (no digest) | ❌ FAIL |
| `public.io/image@sha256:...` (no ACR) | ⚠️ WARN |
| `image:latest` | ❌ FAIL |

---

## CI — Build-once, scan-then-push, cosign verify trước deploy

### image-publish.yml (first-party images)
- `environment: acr-${env}` — dùng release UAMI (`AZURE_CLIENT_ID`), không phải bootstrap identity.
- Build một lần duy nhất (`docker/build-push-action push=false load=true`).
- Trivy scan digest chính xác từ local daemon — không rebuild sau scan.
- `docker push` trực tiếp image đã scan; cache registry được cập nhật bằng bước riêng sau push.
- Cosign sign + verify với exact `github.workflow_ref` identity.

### image-mirror.yml (third-party images)
- Schedule mặc định `env=dev` — không tự động publish lên prod/stg.
- Trivy scan LUÔN chạy kể cả khi push bị skip do idempotency.
- Idempotency: so sánh manifest digest trong ACR với source; bỏ qua push+sign nếu không thay đổi.
- Cosign sign + verify với exact `github.workflow_ref` identity.

### deploy-azure-hub.yml — fail-closed cosign verify
Trước `task install`, workflow đọc `.github/images-to-mirror.yaml` `.images[].target`
và verify từng image với trusted signer identities:
```
https://github.com/amediomediagroup/appmod-blueprints/.github/workflows/image-mirror.yml@refs/heads/main
https://github.com/amediomediagroup/appmod-blueprints/.github/workflows/image-publish.yml@refs/heads/main
```
Issuer: `https://token.actions.githubusercontent.com`.

---

## ACR per environment

| Environment | ACR | Subscription |
|---|---|---|
| dev | `peeks-bootstrap-dev.azurecr.io` | `<dev-subscription>` |
| test | `peeks-bootstrap-test.azurecr.io` | `<test-subscription>` |
| stg | `peeks-bootstrap-stg.azurecr.io` | `<stg-subscription>` |
| prod | `peeks-bootstrap-prod.azurecr.io` | `<prod-subscription>` |

ACR login server được lưu trong Bootstrap Key Vault (`platform-config` secret → field `acrLoginServer`).
