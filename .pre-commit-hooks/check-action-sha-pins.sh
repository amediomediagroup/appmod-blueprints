#!/usr/bin/env bash
# check-action-sha-pins.sh
# Verifies all GitHub Actions `uses:` entries are pinned to a full 40-char commit SHA.
# Floating tags (@v4, @main, @latest) are NOT allowed — they can silently change behavior.
#
# PASS:  uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
# FAIL:  uses: actions/checkout@v7
# FAIL:  uses: actions/checkout@main
# FAIL:  uses: actions/checkout@latest

set -euo pipefail

ERRORS=0

for file in "$@"; do
  # Skip non-workflow files
  [[ "$file" == *".github/workflows/"* ]] || continue

  # Find all `uses:` lines
  while IFS= read -r line; do
    # Extract the action reference after `uses:`
    action=$(echo "$line" | sed 's/.*uses:\s*//' | tr -d '"' | awk '{print $1}')
    [ -z "$action" ] && continue

    # Skip local actions (./.github/actions/...)
    [[ "$action" == ./* ]] && continue

    # Extract the @ref part
    ref="${action##*@}"
    [ -z "$ref" ] && continue

    # Check if ref is a full 40-char hex SHA
    if ! echo "$ref" | grep -qE '^[0-9a-f]{40}$'; then
      echo "❌ $file"
      echo "   Floating tag: $action"
      echo "   Fix: pin to a full commit SHA — e.g. uses: ${action%%@*}@<sha> # $ref"
      ERRORS=$((ERRORS + 1))
    fi
  done < <(grep -E '^\s+uses:\s+' "$file" || true)
done

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "Found $ERRORS floating action tag(s)."
  echo "Pin each action to a full SHA. Get SHA with:"
  echo "  gh api repos/<owner>/<repo>/git/ref/tags/<tag> --jq '.object.sha'"
  exit 1
fi
echo "✓ All GitHub Actions are SHA-pinned"
