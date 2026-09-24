#!/usr/bin/env bash
set -euo pipefail

# integration-test.sh
# Dedicated live-registry integration tests for supply-chain sentinel.

echo "=== Running Supply-Chain Sentinel Integration Tests (Live Network/Registry) ==="

FAILED=0
TOTAL_TESTS=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SUPPLY_CHAIN_DIR="$SCRIPT_DIR"
export PYTHONPATH="$SCRIPT_DIR:${PYTHONPATH:-}"

pass_test() {
    echo "  [PASS] $1"
}

fail_test() {
    echo "  [FAIL] $1 - $2"
    FAILED=$((FAILED + 1))
}

run_test_header() {
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo "Test $TOTAL_TESTS: $1"
}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# TEST 1: Live Skopeo Multi-Arch Resolution (linux/amd64 + linux/arm64)
run_test_header "Live Skopeo Multi-Arch Resolution (linux/amd64 + linux/arm64)"
RESOLVE_MULTI=$(./scripts/supply-chain/resolve-image.sh "grafana/grafana:11.4.0")
AMD64_AVAIL=$(echo "$RESOLVE_MULTI" | jq -r '.platforms["linux/amd64"].available')
ARM64_AVAIL=$(echo "$RESOLVE_MULTI" | jq -r '.platforms["linux/arm64"].available')
TOP_DIGEST=$(echo "$RESOLVE_MULTI" | jq -r '.top_level_digest')
AMD64_DIGEST=$(echo "$RESOLVE_MULTI" | jq -r '.platforms["linux/amd64"].digest')
ARM64_DIGEST=$(echo "$RESOLVE_MULTI" | jq -r '.platforms["linux/arm64"].digest')

if [ "$AMD64_AVAIL" = "true" ] && [ "$ARM64_AVAIL" = "true" ] && [ -n "$TOP_DIGEST" ] && [ "$AMD64_DIGEST" != "$ARM64_DIGEST" ]; then
    pass_test "Multi-arch index resolved separate top-level digest ($TOP_DIGEST) and child digests (amd64=$AMD64_DIGEST, arm64=$ARM64_DIGEST)"
else
    fail_test "Multi-arch resolution" "amd64=$AMD64_AVAIL, arm64=$ARM64_AVAIL, top=$TOP_DIGEST"
fi

# TEST 2: Live Child-Digest Drift Detection (PLATFORM_DIGEST_DRIFT)
run_test_header "Live Child-Digest Drift Detection (PLATFORM_DIGEST_DRIFT)"
mkdir -p "$TMPDIR/test_drift/.supply-chain"
cat << 'EOF' > "$TMPDIR/test_drift/values.yaml"
grafana:
  image:
    repository: grafana/grafana
    tag: 11.4.0
EOF

cat << 'EOF' > "$TMPDIR/test_drift/.supply-chain/artifacts.yaml"
version: "1.0"
images:
  - id: "grafana/grafana:11.4.0"
    image: "grafana/grafana:11.4.0"
    ownership: "THIRD_PARTY_IMAGE"
    source_paths: ["values.yaml"]
    source_tag: "11.4.0"
    top_level_digest: "sha256:d8ea37798ccc41061a62ab080f2676dda6bf7815558499f901bdb0f533a456fb"
    platforms:
      linux/amd64:
        digest: "sha256:8d938a1c52b018c60cb3583657e038054387aa18a74f09a865c99a522481f7ac"
        available: true
      linux/arm64:
        digest: "sha256:OLD_STALE_ARM64_DIGEST_HASH_HERE"
        available: true
EOF

cp .supply-chain/policy.yaml "$TMPDIR/test_drift/.supply-chain/"

COMP_OUT=$(python3 scripts/supply-chain/compare-catalog.py --repo-root "$TMPDIR/test_drift" --scan)
if echo "$COMP_OUT" | grep -q "PLATFORM_DIGEST_DRIFT"; then
    pass_test "PLATFORM_DIGEST_DRIFT correctly detected when child arm64 digest drifted"
else
    fail_test "PLATFORM_DIGEST_DRIFT" "Expected PLATFORM_DIGEST_DRIFT finding in output: $COMP_OUT"
fi

echo "============================================="
if [ "$FAILED" -eq 0 ]; then
    echo "ALL $TOTAL_TESTS INTEGRATION TESTS PASSED SUCCESSFULLY!"
    exit 0
else
    echo "$FAILED / $TOTAL_TESTS INTEGRATION TESTS FAILED!"
    exit 1
fi
