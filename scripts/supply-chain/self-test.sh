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

# TEST 1: Dockerfile discovery with ARG default resolution
run_test_header "Dockerfile discovery with ARG default resolution"
mkdir -p "$TMPDIR/test1/app"
cat << 'EOF' > "$TMPDIR/test1/app/Dockerfile"
ARG BASE_IMAGE=node:22-alpine
FROM ${BASE_IMAGE} AS builder
COPY . .
FROM alpine:3.20
COPY --from=builder /app /app
EOF

DISC_OUT=$(python3 scripts/supply-chain/discover-images.py --repo-root "$TMPDIR/test1")
if echo "$DISC_OUT" | grep -q "node:22-alpine" && echo "$DISC_OUT" | grep -q "alpine:3.20"; then
    pass_test "Dockerfile ARG default (node:22-alpine) resolved successfully"
else
    fail_test "Dockerfile ARG resolution" "Expected node:22-alpine and alpine:3.20 in output: $DISC_OUT"
fi

# TEST 2: Unresolvable Dockerfile ARG detection
run_test_header "Unresolvable Dockerfile ARG detection (UNRESOLVED_DYNAMIC_IMAGE)"
mkdir -p "$TMPDIR/test2/app"
cat << 'EOF' > "$TMPDIR/test2/app/Dockerfile"
ARG BASE_IMAGE
FROM $BASE_IMAGE
EOF

DISC_OUT2=$(python3 scripts/supply-chain/discover-images.py --repo-root "$TMPDIR/test2")
UNRES_COUNT=$(echo "$DISC_OUT2" | jq -r '.unresolved_dynamic_count')
UNRES_VAR=$(echo "$DISC_OUT2" | jq -r '.unresolved_dynamic_images[0].variable_name')

if [ "$UNRES_COUNT" -ge 1 ] && [ "$UNRES_VAR" = "BASE_IMAGE" ]; then
    pass_test "Unresolvable ARG BASE_IMAGE correctly captured as UNRESOLVED_DYNAMIC_IMAGE"
else
    fail_test "Unresolvable ARG detection" "Expected UNRESOLVED_DYNAMIC_IMAGE with BASE_IMAGE, got: $DISC_OUT2"
fi

# TEST 3: Generic OCI reference parsing without registry whitelist
run_test_header "Generic OCI reference parsing (Docker Hub, custom registries, ports, digests)"
mkdir -p "$TMPDIR/test3"
cat << 'EOF' > "$TMPDIR/test3/test_script.sh"
#!/bin/bash
docker pull postgres:17
docker pull redis:alpine
docker pull mcr.microsoft.com/foo/bar:1.2.3
docker pull registry.gitlab.com/group/project/image:v1
docker pull docker.elastic.co/elasticsearch/elasticsearch:9.0.0
docker pull localhost:5000/team/image:dev
docker pull public.ecr.aws/example/team/image:v1
docker pull image@sha256:d8ea37798ccc41061a62ab080f2676dda6bf7815558499f901bdb0f533a456fb
EOF

DISC_OUT3=$(python3 scripts/supply-chain/discover-images.py --repo-root "$TMPDIR/test3")
IMGS=$(echo "$DISC_OUT3" | jq -r '.images[].image')

MISSING=0
for expected_img in "postgres:17" "redis:alpine" "mcr.microsoft.com/foo/bar:1.2.3" "registry.gitlab.com/group/project/image:v1" "docker.elastic.co/elasticsearch/elasticsearch:9.0.0" "localhost:5000/team/image:dev" "public.ecr.aws/example/team/image:v1" "image@sha256:d8ea37798ccc41061a62ab080f2676dda6bf7815558499f901bdb0f533a456fb"; do
    if ! echo "$IMGS" | grep -F -q "$expected_img"; then
        echo "Missing expected OCI reference: $expected_img"
        MISSING=$((MISSING + 1))
    fi
done

if [ "$MISSING" -eq 0 ]; then
    pass_test "All required generic OCI references parsed successfully without whitelist"
else
    fail_test "Generic OCI reference parsing" "$MISSING references missing from: $IMGS"
fi

# TEST 4: Dynamic references in manifests/templates
run_test_header "Dynamic references in manifests/templates"
mkdir -p "$TMPDIR/test4"
cat << 'EOF' > "$TMPDIR/test4/pod.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
spec:
  containers:
  - name: c1
    image: ${DYNAMIC_IMAGE_REF}
  - name: c2
    image: {{ .Values.image.repository }}:{{ .Values.image.tag }}
EOF

DISC_OUT4=$(python3 scripts/supply-chain/discover-images.py --repo-root "$TMPDIR/test4")
UNRES_COUNT4=$(echo "$DISC_OUT4" | jq -r '.unresolved_dynamic_count')

if [ "$UNRES_COUNT4" -ge 2 ]; then
    pass_test "Dynamic references correctly recorded as UNRESOLVED_DYNAMIC_IMAGE"
else
    fail_test "Dynamic reference detection" "Expected at least 2 unresolved dynamic refs, got $UNRES_COUNT4"
fi

# TEST 5: Multi-arch resolution behavior & missing platform detection
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

# TEST 6: Child-digest drift detection (PLATFORM_DIGEST_DRIFT)
run_test_header "Child-digest drift detection (PLATFORM_DIGEST_DRIFT)"
mkdir -p "$TMPDIR/test6/.supply-chain"
cat << 'EOF' > "$TMPDIR/test6/values.yaml"
grafana:
  image:
    repository: grafana/grafana
    tag: 11.4.0
EOF

cat << 'EOF' > "$TMPDIR/test6/.supply-chain/artifacts.yaml"
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

cat << 'EOF' > "$TMPDIR/test6/.supply-chain/policy.yaml"
version: "1.0"
target_platforms: ["linux/amd64", "linux/arm64"]
EOF

COMP_OUT=$(python3 scripts/supply-chain/compare-catalog.py --repo-root "$TMPDIR/test6" --scan)
if echo "$COMP_OUT" | grep -q "PLATFORM_DIGEST_DRIFT"; then
    pass_test "PLATFORM_DIGEST_DRIFT correctly detected when child arm64 digest drifted"
else
    fail_test "PLATFORM_DIGEST_DRIFT" "Expected PLATFORM_DIGEST_DRIFT finding in output: $COMP_OUT"
fi

# TEST 7: New Chart.yaml detection & Chart.lock drift
run_test_header "New Chart.yaml detection & missing Chart.lock detection"
mkdir -p "$TMPDIR/test7/my-chart"
cat << 'EOF' > "$TMPDIR/test7/my-chart/Chart.yaml"
apiVersion: v2
name: my-chart
version: 1.0.0
dependencies:
  - name: redis
    version: 17.0.0
    repository: https://charts.bitnami.com/bitnami
EOF

HELM_DISC=$(python3 scripts/supply-chain/discover-helm.py --repo-root "$TMPDIR/test7")
LOCK_STATE=$(echo "$HELM_DISC" | jq -r '.helm_charts[0].chart_lock_state')

if [ "$LOCK_STATE" = "MISSING" ]; then
    pass_test "Missing Chart.lock correctly detected for chart with dependencies"
else
    fail_test "Chart.lock detection" "Expected MISSING lock state, got $LOCK_STATE"
fi

# TEST 8: Internal GitOps chart classification
run_test_header "Internal GitOps chart classification"
mkdir -p "$TMPDIR/test8/platform-charts/my-oci-chart"
mkdir -p "$TMPDIR/test8/gitops/addons/my-addon-chart"
cat << 'EOF' > "$TMPDIR/test8/platform-charts/my-oci-chart/Chart.yaml"
apiVersion: v2
name: my-oci-chart
version: 0.1.0
EOF
cat << 'EOF' > "$TMPDIR/test8/gitops/addons/my-addon-chart/Chart.yaml"
apiVersion: v2
name: my-addon-chart
version: 0.1.0
EOF

HELM_CLASS=$(python3 scripts/supply-chain/discover-helm.py --repo-root "$TMPDIR/test8")
CLASS_OCI=$(echo "$HELM_CLASS" | jq -r '.helm_charts[] | select(.chart_name=="my-oci-chart") | .classification')
CLASS_GITOPS=$(echo "$HELM_CLASS" | jq -r '.helm_charts[] | select(.chart_name=="my-addon-chart") | .classification')

if [ "$CLASS_OCI" = "RELEASE_ARTIFACT_OCI_CANDIDATE" ] && [ "$CLASS_GITOPS" = "INTERNAL_GITOPS_WRAPPER" ]; then
    pass_test "Charts correctly classified (OCI candidate vs Internal GitOps wrapper)"
else
    fail_test "Chart classification" "OCI=$CLASS_OCI, GitOps=$CLASS_GITOPS"
fi

# TEST 9: Deterministic findings JSON output
run_test_header "Deterministic findings output"
mkdir -p "$TMPDIR/test9/.supply-chain"
cp .supply-chain/policy.yaml "$TMPDIR/test9/.supply-chain/"
python3 scripts/supply-chain/compare-catalog.py --repo-root "$TMPDIR/test9" --update-catalog --output "$TMPDIR/test9/out1.json"
python3 scripts/supply-chain/compare-catalog.py --repo-root "$TMPDIR/test9" --output "$TMPDIR/test9/out2.json"

if [ -s "$TMPDIR/test9/out1.json" ] && [ -s "$TMPDIR/test9/out2.json" ]; then
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
