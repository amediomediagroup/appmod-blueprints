#!/usr/bin/env bash
# check-image-digest.sh
# Enforces image security policy for Azure Container Registry (ACR):
#   1. Production images (K8s manifests) should reference ACR (*.azurecr.io)
#   2. All images must be pinned to SHA digest (@sha256:<64-hex>)
#   3. Mutable tags (latest, edge, dev, nightly) are always errors
#
# PASS:  image: myregistry.azurecr.io/nginx@sha256:1a2b3c...
# PASS:  image: myregistry.azurecr.io/nginx:1.25.3@sha256:1a2b3c...
# WARN:  image: nginx:1.25.3@sha256:1a2b3c...           (non-ACR but digest-pinned)
# FAIL:  image: nginx:1.25.3                             (no digest)
# FAIL:  image: nginx:latest                             (mutable tag)
# SKIP:  image: "{{ .Values.image }}"                   (Helm template)
# SKIP:  image: $IMAGE_NAME                             (shell variable)
#
# To migrate to ACR + get digest:
#   az acr import --name <acr> --source nginx:1.25.3 --image nginx:1.25.3
#   az acr manifest list-metadata --registry <acr> --name nginx --query "[?tags[?@=='1.25.3']].digest"

set -euo pipefail

ERRORS=0
WARNINGS=0

# ACR pattern
ACR_PATTERN='\.azurecr\.io/'

# SHA digest pattern (64 hex chars)
DIGEST_PATTERN='@sha256:[0-9a-f]{64}'

# Mutable/unstable tags
MUTABLE_TAGS='latest|edge|dev|nightly|canary|snapshot|main|master|HEAD'

# Skip templates and variables
SKIP_PATTERN='\{\{|\$\{|\$[A-Z_]|^[[:space:]]*$|^null$|^~$|^""$'

# Only check K8s manifests and values — skip Chart.yaml (chart metadata, not image refs)
for file in "$@"; do
  # Skip Chart.yaml (version fields, not image refs)
  [[ "$(basename "$file")" == "Chart.yaml" ]] && continue

  line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))

    if echo "$line" | grep -qE '^\s+(image|repository):\s+[^\s]'; then
      img=$(echo "$line" | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" | awk '{print $1}')

      # Skip templates and variables
      echo "$img" | grep -qE "$SKIP_PATTERN" && continue
      [ -z "$img" ] && continue

      # Mutable tags are always errors
      if echo "$img" | grep -qiE ":(${MUTABLE_TAGS})$"; then
        echo "❌ $file:$line_num — mutable tag: $img"
        echo "   Import to ACR and pin with digest: az acr import --name <acr> --source $img"
        ERRORS=$((ERRORS + 1))
        continue
      fi

      is_acr=$(echo "$img" | grep -qE "$ACR_PATTERN" && echo true || echo false)
      has_digest=$(echo "$img" | grep -qE "@sha256:[0-9a-f]{64}" && echo true || echo false)

      if [ "$has_digest" = "false" ]; then
        if [ "$is_acr" = "true" ]; then
          # ACR image without digest — error
          echo "❌ $file:$line_num — ACR image missing digest: $img"
          echo "   Pin: $img@sha256:<digest>"
          ERRORS=$((ERRORS + 1))
        else
          # Non-ACR image without digest — error
          echo "❌ $file:$line_num — image missing digest: $img"
          echo "   Import to ACR: az acr import --name <acr> --source $img"
          echo "   Then pin with digest: <acr>.azurecr.io/${img##*/}@sha256:<digest>"
          ERRORS=$((ERRORS + 1))
        fi
      elif [ "$is_acr" = "false" ]; then
        # Digest-pinned but not ACR — warning only (may be bootstrap/system images)
        echo "⚠️  $file:$line_num — digest-pinned but not ACR: $img"
        echo "   Prefer ACR for audit trail and Cosign signing"
        WARNINGS=$((WARNINGS + 1))
      fi
      # ACR + digest = PASS (no output)
    fi
  done < "$file"
done

if [ "$WARNINGS" -gt 0 ]; then
  echo ""
  echo "⚠️  $WARNINGS image(s) are not in ACR."
  echo "   Import with: az acr import --name <acr> --source <image> --image <name>:<tag>"
fi

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "❌ $ERRORS image(s) require fixes. All images must:"
  echo "   1. Be imported to ACR (*.azurecr.io)"
  echo "   2. Be pinned to SHA digest (@sha256:64hex)"
  exit 1
fi

exit 0
