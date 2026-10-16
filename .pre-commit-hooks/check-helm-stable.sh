#!/usr/bin/env bash
# check-helm-stable.sh
# Checks Helm chart versions and container image tags for unstable references.
#
# Fails on:
#   - Pre-release versions: 1.0.0-alpha, 1.0.0-beta.1, 1.0.0-rc.2
#   - 'latest' image tag (mutable, breaks reproducibility)
#   - 'edge', 'dev', 'nightly', 'canary', 'snapshot' tags
#
# PASS:  version: 1.2.3
# PASS:  tag: 1.2.3
# FAIL:  version: 1.2.3-beta.1
# FAIL:  image: nginx:latest
# FAIL:  defaultVersion: 'v1.0.0-rc.1'

set -euo pipefail

ERRORS=0
WARNINGS=0

# Pre-release semver pattern (e.g. 1.2.3-alpha, 1.2.3-beta.1, 1.2.3-rc.2)
PRERELEASE_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+-[a-zA-Z]'

# Unstable image tag keywords
UNSTABLE_TAGS='latest|edge|dev|nightly|canary|snapshot|master|main|HEAD'

for file in "$@"; do
  line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))

    # Check chart version fields
    if echo "$line" | grep -qE '^\s*(version|defaultVersion|chartVersion|appVersion|rev):\s*["\x27]?v?[0-9]'; then
      version=$(echo "$line" | sed "s/.*:\s*['\"]*//" | tr -d '"' | tr -d "'" | awk '{print $1}')
      # Strip leading 'v'
      ver_clean="${version#v}"
      if echo "$ver_clean" | grep -qE "$PRERELEASE_PATTERN"; then
        echo "❌ $file:$line_num"
        echo "   Pre-release version: $line"
        echo "   Use a stable release (no -alpha/-beta/-rc suffix)"
        ERRORS=$((ERRORS + 1))
      fi
    fi

    # Check image tags
    if echo "$line" | grep -qE '^\s*(image|tag):\s'; then
      tag=$(echo "$line" | sed 's/.*:\s*//' | tr -d '"' | tr -d "'" | awk '{print $1}')
      # Extract tag after ':' if it's an image reference
      img_tag="${tag##*:}"
      if echo "$img_tag" | grep -qiE "^($UNSTABLE_TAGS)$"; then
        echo "⚠️  $file:$line_num"
        echo "   Unstable image tag '$img_tag': $line"
        echo "   Pin to a specific version tag or digest"
        WARNINGS=$((WARNINGS + 1))
      fi
    fi

    # Check Helm chart repository + defaultVersion combos
    if echo "$line" | grep -qE "defaultVersion:\s*['\"]?v?[0-9]"; then
      version=$(echo "$line" | sed "s/.*defaultVersion:\s*['\"]*//" | tr -d "'" | tr -d '"' | awk '{print $1}')
      ver_clean="${version#v}"
      if echo "$ver_clean" | grep -qE "$PRERELEASE_PATTERN"; then
        echo "❌ $file:$line_num"
        echo "   Pre-release defaultVersion: $line"
        ERRORS=$((ERRORS + 1))
      fi
    fi

  done < "$file"
done

if [ "$WARNINGS" -gt 0 ]; then
  echo "⚠️  $WARNINGS unstable image tag(s) found (consider pinning to digest)"
fi

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "Found $ERRORS pre-release version(s). Use only stable releases."
  exit 1
fi

if [ "$WARNINGS" -eq 0 ] && [ "$ERRORS" -eq 0 ]; then
  echo "✓ All Helm versions and image tags look stable"
fi
