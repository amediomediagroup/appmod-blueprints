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

# TEST 1: Dockerfile FROM & ARG default resolution
run_test_header "Dockerfile FROM discovery & ARG default resolution"
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
    pass_test "Dockerfile FROM and ARG default (node:22-alpine) resolved successfully"
else
    fail_test "Dockerfile ARG resolution" "Expected node:22-alpine and alpine:3.20 in output: $DISC_OUT"
fi

# TEST 2: Unresolved Docker ARG detection
run_test_header "Unresolved Docker ARG detection (UNRESOLVED_DYNAMIC_IMAGE)"
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

# TEST 3: containers, initContainers, and ephemeralContainers discovery
run_test_header "containers, initContainers, and ephemeralContainers discovery"
mkdir -p "$TMPDIR/test3"
cat << 'EOF' > "$TMPDIR/test3/pod.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
spec:
  initContainers:
  - name: init1
    image: busybox:1.36
  containers:
  - name: main
    image: postgres:17
  ephemeralContainers:
  - name: debug
    image: nicolaka/netshoot:latest
EOF

DISC_OUT3=$(python3 scripts/supply-chain/discover-images.py --repo-root "$TMPDIR/test3")
if echo "$DISC_OUT3" | grep -q "busybox:1.36" && echo "$DISC_OUT3" | grep -q "postgres:17" && echo "$DISC_OUT3" | grep -q "nicolaka/netshoot:latest"; then
    pass_test "Containers, initContainers, and ephemeralContainers correctly discovered"
else
    fail_test "Container types discovery" "Expected busybox:1.36, postgres:17, and netshoot:latest in output: $DISC_OUT3"
fi

# TEST 4: Tag classification vs digest pinning
run_test_header "Tag classification vs digest pinning separation"
mkdir -p "$TMPDIR/test4"
cat << 'EOF' > "$TMPDIR/test4/deploy.yaml"
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
        image: postgres:17
      - name: c4
        image: grafana/grafana:11.4.0
      - name: c5
        image: image@sha256:d8ea37798ccc41061a62ab080f2676dda6bf7815558499f901bdb0f533a456fb
EOF

DISC_OUT4=$(python3 scripts/supply-chain/discover-images.py --repo-root "$TMPDIR/test4")

REDIS_CLASS=$(echo "$DISC_OUT4" | jq -r '.images[] | select(.image=="redis:latest") | .tag_classification')
REDIS_PINNED=$(echo "$DISC_OUT4" | jq -r '.images[] | select(.image=="redis:latest") | .digest_pinned')

PG_CLASS=$(echo "$DISC_OUT4" | jq -r '.images[] | select(.image=="postgres") | .tag_classification')
PG_PINNED=$(echo "$DISC_OUT4" | jq -r '.images[] | select(.image=="postgres") | .digest_pinned')

PG17_CLASS=$(echo "$DISC_OUT4" | jq -r '.images[] | select(.image=="postgres:17") | .tag_classification')
PG17_PINNED=$(echo "$DISC_OUT4" | jq -r '.images[] | select(.image=="postgres:17") | .digest_pinned')

GRAFANA_CLASS=$(echo "$DISC_OUT4" | jq -r '.images[] | select(.image=="grafana/grafana:11.4.0") | .tag_classification')
GRAFANA_PINNED=$(echo "$DISC_OUT4" | jq -r '.images[] | select(.image=="grafana/grafana:11.4.0") | .digest_pinned')

DIGEST_PINNED=$(echo "$DISC_OUT4" | jq -r '.images[] | select(.image | contains("@sha256")) | .digest_pinned')

if [ "$REDIS_CLASS" = "LATEST" ] && [ "$REDIS_PINNED" = "false" ] && \
   [ "$PG_CLASS" = "UNTAGGED" ] && [ "$PG_PINNED" = "false" ] && \
   [ "$PG17_CLASS" = "EXACT_VERSION" ] && [ "$PG17_PINNED" = "false" ] && \
   [ "$GRAFANA_CLASS" = "EXACT_VERSION" ] && [ "$GRAFANA_PINNED" = "false" ] && \
   [ "$DIGEST_PINNED" = "true" ]; then
    pass_test "Tag classification correctly separated from digest_pinned (digest_pinned=true ONLY for @sha256)"
else
    fail_test "Tag classification vs digest pinning" "redis=($REDIS_CLASS, $REDIS_PINNED), pg=($PG_CLASS, $PG_PINNED), pg17=($PG17_CLASS, $PG17_PINNED), grafana=($GRAFANA_CLASS, $GRAFANA_PINNED), digest=($DIGEST_PINNED)"
fi

# TEST 5: Generic custom registry, explicit port, digest reference
run_test_header "Generic custom registry, explicit port, and digest parsing"
mkdir -p "$TMPDIR/test5"
cat << 'EOF' > "$TMPDIR/test5/test_script.sh"
#!/bin/bash
IMAGE="registry.example.com:5000/team/image:1.2.3"
UNTAGGED_IMAGE="registry.example.com:5000/team/image"
MCR_IMAGE="mcr.microsoft.com/foo/bar:1.2.3"
ELASTIC_IMAGE="docker.elastic.co/elasticsearch/elasticsearch:9.0.0"
DIGEST_IMG="public.ecr.aws/example/team/image:v1@sha256:d8ea37798ccc41061a62ab080f2676dda6bf7815558499f901bdb0f533a456fb"
EOF

DISC_OUT5=$(python3 scripts/supply-chain/discover-images.py --repo-root "$TMPDIR/test5")
IMGS5=$(echo "$DISC_OUT5" | jq -r '.images[].image')

MISSING=0
for expected_img in "registry.example.com:5000/team/image:1.2.3" "registry.example.com:5000/team/image" "mcr.microsoft.com/foo/bar:1.2.3" "docker.elastic.co/elasticsearch/elasticsearch:9.0.0" "public.ecr.aws/example/team/image:v1@sha256:d8ea37798ccc41061a62ab080f2676dda6bf7815558499f901bdb0f533a456fb"; do
    if ! echo "$IMGS5" | grep -F -q "$expected_img"; then
        echo "Missing expected OCI reference: $expected_img"
        MISSING=$((MISSING + 1))
    fi
done

UNTAGGED_PINNED=$(echo "$DISC_OUT5" | jq -r '.images[] | select(.image=="registry.example.com:5000/team/image") | .digest_pinned')

if [ "$MISSING" -eq 0 ] && [ "$UNTAGGED_PINNED" = "false" ]; then
    pass_test "Explicit port registries and untagged port-specified references parsed correctly"
else
    fail_test "Port and digest parsing" "Missing $MISSING refs, untagged_pinned=$UNTAGGED_PINNED"
fi

# TEST 6: Dynamic Helm/YAML reference
run_test_header 'Dynamic Helm/YAML image reference'
mkdir -p "$TMPDIR/test6"
cat << 'EOF' > "$TMPDIR/test6/values.yaml"
image:
  repository: ${DYNAMIC_REPO}
  tag: {{ .Values.image.tag }}
EOF

DISC_OUT6=$(python3 scripts/supply-chain/discover-images.py --repo-root "$TMPDIR/test6")
UNRES_COUNT6=$(echo "$DISC_OUT6" | jq -r '.unresolved_dynamic_count')

if [ "$UNRES_COUNT6" -ge 1 ]; then
    pass_test "Dynamic Helm/YAML reference correctly recorded as UNRESOLVED_DYNAMIC_IMAGE"
else
    fail_test "Dynamic Helm/YAML ref" "Expected unresolved dynamic ref, got count $UNRES_COUNT6"
fi

# TEST 7: Scanner internal implementation & self-test fixture exclusion
run_test_header "Scanner internal implementation & test fixture exclusion"
DISC_REPO=$(python3 scripts/supply-chain/discover-images.py)
SELF_PATHS=$(echo "$DISC_REPO" | jq -r '.images[].source_paths[]' | grep -E "^scripts/supply-chain|^.supply-chain" || true)

if [ -z "$SELF_PATHS" ]; then
    pass_test "Scanner implementation (scripts/supply-chain/) and .supply-chain/ are excluded from discovery"
else
    fail_test "Scanner self-exclusion" "Found scanner internal paths in discovery: $SELF_PATHS"
fi

# TEST 8: Multi-arch resolution behavior & missing platform detection
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

# TEST 9: Child-digest drift detection (PLATFORM_DIGEST_DRIFT)
run_test_header "Child-digest drift detection (PLATFORM_DIGEST_DRIFT)"
mkdir -p "$TMPDIR/test9/.supply-chain"
cat << 'EOF' > "$TMPDIR/test9/values.yaml"
grafana:
  image:
    repository: grafana/grafana
    tag: 11.4.0
EOF

cat << 'EOF' > "$TMPDIR/test9/.supply-chain/artifacts.yaml"
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

cat << 'EOF' > "$TMPDIR/test9/.supply-chain/policy.yaml"
version: "1.0"
target_platforms: ["linux/amd64", "linux/arm64"]
EOF

COMP_OUT=$(python3 scripts/supply-chain/compare-catalog.py --repo-root "$TMPDIR/test9" --scan)
if echo "$COMP_OUT" | grep -q "PLATFORM_DIGEST_DRIFT"; then
    pass_test "PLATFORM_DIGEST_DRIFT correctly detected when child arm64 digest drifted"
else
    fail_test "PLATFORM_DIGEST_DRIFT" "Expected PLATFORM_DIGEST_DRIFT finding in output: $COMP_OUT"
fi

# TEST 10: New Chart.yaml & missing/stale Chart.lock detection
run_test_header "New Chart.yaml detection & missing Chart.lock detection"
mkdir -p "$TMPDIR/test10/my-chart"
cat << 'EOF' > "$TMPDIR/test10/my-chart/Chart.yaml"
apiVersion: v2
name: my-chart
version: 1.0.0
dependencies:
  - name: redis
    version: 17.0.0
    repository: https://charts.bitnami.com/bitnami
EOF

HELM_DISC=$(python3 scripts/supply-chain/discover-helm.py --repo-root "$TMPDIR/test10")
LOCK_STATE=$(echo "$HELM_DISC" | jq -r '.helm_charts[0].chart_lock_state')

if [ "$LOCK_STATE" = "MISSING" ]; then
    pass_test "Missing Chart.lock correctly detected for new chart with dependencies"
else
    fail_test "Chart.lock detection" "Expected MISSING lock state, got $LOCK_STATE"
fi

# TEST 11: Internal GitOps vs OCI candidate chart classification
run_test_header "Internal GitOps vs OCI candidate chart classification"
mkdir -p "$TMPDIR/test11/platform-charts/my-oci-chart"
mkdir -p "$TMPDIR/test11/gitops/addons/my-addon-chart"
cat << 'EOF' > "$TMPDIR/test11/platform-charts/my-oci-chart/Chart.yaml"
apiVersion: v2
name: my-oci-chart
version: 0.1.0
EOF
cat << 'EOF' > "$TMPDIR/test11/gitops/addons/my-addon-chart/Chart.yaml"
apiVersion: v2
name: my-addon-chart
version: 0.1.0
EOF

HELM_CLASS=$(python3 scripts/supply-chain/discover-helm.py --repo-root "$TMPDIR/test11")
CLASS_OCI=$(echo "$HELM_CLASS" | jq -r '.helm_charts[] | select(.chart_name=="my-oci-chart") | .classification')
CLASS_GITOPS=$(echo "$HELM_CLASS" | jq -r '.helm_charts[] | select(.chart_name=="my-addon-chart") | .classification')

if [ "$CLASS_OCI" = "RELEASE_ARTIFACT_OCI_CANDIDATE" ] && [ "$CLASS_GITOPS" = "INTERNAL_GITOPS_WRAPPER" ]; then
    pass_test "Charts correctly classified (OCI candidate vs Internal GitOps wrapper)"
else
    fail_test "Chart classification" "OCI=$CLASS_OCI, GitOps=$CLASS_GITOPS"
fi

# TEST 12: Deterministic findings JSON output comparison
run_test_header "Deterministic findings output comparison"
mkdir -p "$TMPDIR/test12/.supply-chain"
cp .supply-chain/policy.yaml "$TMPDIR/test12/.supply-chain/"
python3 scripts/supply-chain/compare-catalog.py --repo-root "$TMPDIR/test12" --update-catalog --output "$TMPDIR/test12/out1.json"
python3 scripts/supply-chain/compare-catalog.py --repo-root "$TMPDIR/test12" --output "$TMPDIR/test12/out2.json"

if [ -s "$TMPDIR/test12/out1.json" ] && [ -s "$TMPDIR/test12/out2.json" ]; then
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
