# Azure Image Security — ACR + Cosign

> Provider: `kind-crossplane-azure`
> Last updated: 2026-10-16

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

# Verify
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp "^https://github.com/<org>/<repo>" \
  <acr-name>.azurecr.io/nginx@sha256:<digest>
```

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

## CI — Cosign verify trước deploy

`deploy-azure-hub.yml` chạy `cosign verify` sau `task install`:
- Kiểm tra tất cả images trong ACR có signature hợp lệ
- Warn nếu chưa signed (không block trong giai đoạn rollout)
- Upgrade lên `exit-code=1` khi toàn bộ images đã được ký

---

## ACR per environment

| Environment | ACR | Subscription |
|---|---|---|
| dev | `peeks-bootstrap-dev.azurecr.io` | `<dev-subscription>` |
| test | `peeks-bootstrap-test.azurecr.io` | `<test-subscription>` |
| stg | `peeks-bootstrap-stg.azurecr.io` | `<stg-subscription>` |
| prod | `peeks-bootstrap-prod.azurecr.io` | `<prod-subscription>` |

ACR login server được lưu trong Bootstrap Key Vault (`platform-config` secret → field `acrLoginServer`).
