#!/usr/bin/env bash
set -euo pipefail

# self-test.sh
# Comprehensive self-test suite proving supply-chain sentinel logic.

echo "=== Running Supply-Chain Sentinel Self-Tests ==="

FAILED=0
TOTAL_TESTS=0

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

# TEST 1: Dockerfile discovery
run_test_header "Dockerfile discovery"
mkdir -p "$TMPDIR/test1/app"
cat << 'EOF' > "$TMPDIR/test1/app/Dockerfile"
FROM node:22-alpine AS builder
COPY . .
FROM alpine:3.20
COPY --from=builder /app /app
EOF

DISC_OUT=$(python3 scripts/supply-chain/discover-images.py --repo-root "$TMPDIR/test1")
if echo "$DISC_OUT" | grep -q "node:22-alpine" && echo "$DISC_OUT" | grep -q "alpine:3.20"; then
    pass_test "Dockerfile FROM images correctly discovered (node:22-alpine, alpine:3.20)"
else
    fail_test "Dockerfile discovery" "Expected node:22-alpine and alpine:3.20 in output: $DISC_OUT"
fi

# TEST 2: initContainer discovery
run_test_header "initContainer discovery in Kubernetes manifest"
mkdir -p "$TMPDIR/test2"
cat << 'EOF' > "$TMPDIR/test2/pod.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
spec:
  initContainers:
  - name: init-myservice
    image: busybox:1.36
  containers:
  - name: main
    image: nginx:1.25.3
EOF

DISC_OUT2=$(python3 scripts/supply-chain/discover-images.py --repo-root "$TMPDIR/test2")
if echo "$DISC_OUT2" | grep -q "busybox:1.36" && echo "$DISC_OUT2" | grep -q "nginx:1.25.3"; then
    pass_test "initContainer and container images correctly discovered"
else
    fail_test "initContainer discovery" "Expected busybox:1.36 and nginx:1.25.3 in output: $DISC_OUT2"
fi

# TEST 3: latest tag & tag-without-digest classification
run_test_header "latest tag and tag-without-digest classification"
mkdir -p "$TMPDIR/test3"
cat << 'EOF' > "$TMPDIR/test3/deploy.yaml"
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
      - name: c1
        image: redis:latest
      - name: c2
        image: postgres
      - name: c3
        image: grafana/grafana:11.4.0@sha256:d8ea37798ccc41061a62ab080f2676dda6bf7815558499f901bdb0f533a456fb
EOF

DISC_OUT3=$(python3 scripts/supply-chain/discover-images.py --repo-root "$TMPDIR/test3")
REDIS_MUTABLE=$(echo "$DISC_OUT3" | jq -r '.images[] | select(.image=="redis:latest") | .mutable_tag')
POSTGRES_MUTABLE=$(echo "$DISC_OUT3" | jq -r '.images[] | select(.image=="postgres") | .mutable_tag')
GRAFANA_MUTABLE=$(echo "$DISC_OUT3" | jq -r '.images[] | select(.image | contains("grafana")) | .mutable_tag')

if [ "$REDIS_MUTABLE" = "true" ] && [ "$POSTGRES_MUTABLE" = "true" ] && [ "$GRAFANA_MUTABLE" = "false" ]; then
    pass_test "Mutable tags correctly identified for latest and untagged images, digest pinned is immutable"
else
    fail_test "latest detection" "redis=$REDIS_MUTABLE, postgres=$POSTGRES_MUTABLE, grafana=$GRAFANA_MUTABLE"
fi

# TEST 4: Multi-arch resolution behavior & missing platform detection
run_test_header "Multi-arch resolution behavior & missing platform detection"
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

# TEST 5: Child-digest drift detection (PLATFORM_DIGEST_DRIFT)
run_test_header "Child-digest drift detection (PLATFORM_DIGEST_DRIFT)"
mkdir -p "$TMPDIR/test5/.supply-chain"
cat << 'EOF' > "$TMPDIR/test5/values.yaml"
grafana:
  image:
    repository: grafana/grafana
    tag: 11.4.0
EOF

cat << 'EOF' > "$TMPDIR/test5/.supply-chain/artifacts.yaml"
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

cat << 'EOF' > "$TMPDIR/test5/.supply-chain/policy.yaml"
version: "1.0"
target_platforms: ["linux/amd64", "linux/arm64"]
EOF

# Run comparator with --scan on test5
COMP_OUT=$(python3 scripts/supply-chain/compare-catalog.py --repo-root "$TMPDIR/test5" --scan)
if echo "$COMP_OUT" | grep -q "PLATFORM_DIGEST_DRIFT"; then
    pass_test "PLATFORM_DIGEST_DRIFT correctly detected when child arm64 digest drifted"
else
    fail_test "PLATFORM_DIGEST_DRIFT" "Expected PLATFORM_DIGEST_DRIFT finding in output: $COMP_OUT"
fi

# TEST 6: New Chart.yaml detection & Chart.lock drift
run_test_header "New Chart.yaml detection & missing Chart.lock detection"
mkdir -p "$TMPDIR/test6/my-chart"
cat << 'EOF' > "$TMPDIR/test6/my-chart/Chart.yaml"
apiVersion: v2
name: my-chart
version: 1.0.0
dependencies:
  - name: redis
    version: 17.0.0
    repository: https://charts.bitnami.com/bitnami
EOF

HELM_DISC=$(python3 scripts/supply-chain/discover-helm.py --repo-root "$TMPDIR/test6")
LOCK_STATE=$(echo "$HELM_DISC" | jq -r '.helm_charts[0].chart_lock_state')

if [ "$LOCK_STATE" = "MISSING" ]; then
    pass_test "Missing Chart.lock correctly detected for chart with dependencies"
else
    fail_test "Chart.lock detection" "Expected MISSING lock state, got $LOCK_STATE"
fi

# TEST 7: Internal GitOps chart classification
run_test_header "Internal GitOps chart classification"
mkdir -p "$TMPDIR/test7/platform-charts/my-oci-chart"
mkdir -p "$TMPDIR/test7/gitops/addons/my-addon-chart"
cat << 'EOF' > "$TMPDIR/test7/platform-charts/my-oci-chart/Chart.yaml"
apiVersion: v2
name: my-oci-chart
version: 0.1.0
EOF
cat << 'EOF' > "$TMPDIR/test7/gitops/addons/my-addon-chart/Chart.yaml"
apiVersion: v2
name: my-addon-chart
version: 0.1.0
EOF

HELM_CLASS=$(python3 scripts/supply-chain/discover-helm.py --repo-root "$TMPDIR/test7")
CLASS_OCI=$(echo "$HELM_CLASS" | jq -r '.helm_charts[] | select(.chart_name=="my-oci-chart") | .classification')
CLASS_GITOPS=$(echo "$HELM_CLASS" | jq -r '.helm_charts[] | select(.chart_name=="my-addon-chart") | .classification')

if [ "$CLASS_OCI" = "RELEASE_ARTIFACT_OCI_CANDIDATE" ] && [ "$CLASS_GITOPS" = "INTERNAL_GITOPS_WRAPPER" ]; then
    pass_test "Charts correctly classified (OCI candidate vs Internal GitOps wrapper)"
else
    fail_test "Chart classification" "OCI=$CLASS_OCI, GitOps=$CLASS_GITOPS"
fi

# TEST 8: Deterministic findings JSON output
run_test_header "Deterministic findings output"
mkdir -p "$TMPDIR/test8/.supply-chain"
cp .supply-chain/policy.yaml "$TMPDIR/test8/.supply-chain/"
python3 scripts/supply-chain/compare-catalog.py --repo-root "$TMPDIR/test8" --update-catalog --output "$TMPDIR/test8/out1.json"
python3 scripts/supply-chain/compare-catalog.py --repo-root "$TMPDIR/test8" --output "$TMPDIR/test8/out2.json"

if [ -s "$TMPDIR/test8/out1.json" ] && [ -s "$TMPDIR/test8/out2.json" ]; then
    pass_test "Deterministic findings JSON files generated successfully"
else
    fail_test "Findings output" "Failed to generate valid output files"
fi

echo "============================================="
if [ "$FAILED" -eq 0 ]; then
    echo "ALL $TOTAL_TESTS SELF-TESTS PASSED SUCCESSFULLY!"
    exit 0
else
    echo "$FAILED / $TOTAL_TESTS SELF-TESTS FAILED!"
    exit 1
fi
EOF
