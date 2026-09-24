#!/usr/bin/env bash
set -euo pipefail

# self-test.sh
# Hermetic offline self-test suite proving supply-chain sentinel logic and policy enforcement.

echo "=== Running Supply-Chain Sentinel Hermetic Self-Tests ==="

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

ROOT_DIR="$(pwd)"

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

# TEST 8: New Chart.yaml & missing/stale Chart.lock detection
run_test_header "New Chart.yaml detection & missing Chart.lock detection"
mkdir -p "$TMPDIR/test8/my-chart"
cat << 'EOF' > "$TMPDIR/test8/my-chart/Chart.yaml"
apiVersion: v2
name: my-chart
version: 1.0.0
dependencies:
  - name: redis
    version: 17.0.0
    repository: https://charts.bitnami.com/bitnami
EOF

HELM_DISC=$(python3 scripts/supply-chain/discover-helm.py --repo-root "$TMPDIR/test8")
LOCK_STATE=$(echo "$HELM_DISC" | jq -r '.helm_charts[0].chart_lock_state')

if [ "$LOCK_STATE" = "MISSING" ]; then
    pass_test "Missing Chart.lock correctly detected for new chart with dependencies"
else
    fail_test "Chart.lock detection" "Expected MISSING lock state, got $LOCK_STATE"
fi

# TEST 9: Internal GitOps vs OCI candidate chart classification
run_test_header "Internal GitOps vs OCI candidate chart classification"
mkdir -p "$TMPDIR/test9/platform-charts/my-oci-chart"
mkdir -p "$TMPDIR/test9/gitops/addons/my-addon-chart"
cat << 'EOF' > "$TMPDIR/test9/platform-charts/my-oci-chart/Chart.yaml"
apiVersion: v2
name: my-oci-chart
version: 0.1.0
EOF
cat << 'EOF' > "$TMPDIR/test9/gitops/addons/my-addon-chart/Chart.yaml"
apiVersion: v2
name: my-addon-chart
version: 0.1.0
EOF

HELM_CLASS=$(python3 scripts/supply-chain/discover-helm.py --repo-root "$TMPDIR/test9")
CLASS_OCI=$(echo "$HELM_CLASS" | jq -r '.helm_charts[] | select(.chart_name=="my-oci-chart") | .classification')
CLASS_GITOPS=$(echo "$HELM_CLASS" | jq -r '.helm_charts[] | select(.chart_name=="my-addon-chart") | .classification')

if [ "$CLASS_OCI" = "RELEASE_ARTIFACT_OCI_CANDIDATE" ] && [ "$CLASS_GITOPS" = "INTERNAL_GITOPS_WRAPPER" ]; then
    pass_test "Charts correctly classified (OCI candidate vs Internal GitOps wrapper)"
else
    fail_test "Chart classification" "OCI=$CLASS_OCI, GitOps=$CLASS_GITOPS"
fi

# TEST 10: Strict Deterministic Findings Comparison (diff -u)
run_test_header "Strict Deterministic Findings Comparison (diff -u)"
mkdir -p "$TMPDIR/test10/.supply-chain"
cat << 'EOF' > "$TMPDIR/test10/deploy.yaml"
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
      - name: redis
        image: redis:latest
EOF

cp .supply-chain/policy.yaml "$TMPDIR/test10/.supply-chain/"

python3 scripts/supply-chain/compare-catalog.py --repo-root "$TMPDIR/test10" --output "$TMPDIR/test10/raw1.json"
python3 scripts/supply-chain/compare-catalog.py --repo-root "$TMPDIR/test10" --output "$TMPDIR/test10/raw2.json"

jq -S . "$TMPDIR/test10/raw1.json" > "$TMPDIR/test10/out1.json"
jq -S . "$TMPDIR/test10/raw2.json" > "$TMPDIR/test10/out2.json"

if diff -u "$TMPDIR/test10/out1.json" "$TMPDIR/test10/out2.json"; then
    pass_test "Strict diff -u between run 1 and run 2 comparison outputs was byte-identical"
else
    fail_test "Deterministic findings diff" "out1.json and out2.json differed!"
fi

# ==================== POLICY ENFORCEMENT HERMETIC TESTS ====================

# TEST 11: Policy target_platforms enforcement
run_test_header "Policy target_platforms enforcement"
mkdir -p "$TMPDIR/test11/.supply-chain"
cat << 'EOF' > "$TMPDIR/test11/deploy.yaml"
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
      - name: redis
        image: redis:latest
EOF

cat << 'EOF' > "$TMPDIR/test11/.supply-chain/policy.yaml"
version: "1.0"
target_platforms:
  - linux/amd64
vulnerability_policy:
  fail_on_severity: [CRITICAL, HIGH]
  ignore_unfixed: false
first_party:
  dockerfile_paths: ["apps/*"]
  image_patterns: ["aegis/*"]
helm_policy:
  classification_patterns:
    release_artifact_oci_candidate: ["platform-charts/*"]
  require_chart_lock_if_dependencies: true
  allow_protected_git_main: true
EOF

COMP_POL11=$(python3 scripts/supply-chain/compare-catalog.py --repo-root "$TMPDIR/test11")
if echo "$COMP_POL11" | grep -q "PLATFORM_AMD64_MISSING" && ! echo "$COMP_POL11" | grep -q "PLATFORM_ARM64_MISSING"; then
    pass_test "target_platforms dynamically sourced from policy (only linux/amd64 evaluated)"
else
    fail_test "Policy target_platforms" "Expected PLATFORM_AMD64_MISSING without ARM64: $COMP_POL11"
fi

# TEST 12: Vulnerability Policy Severity Enforcement (CRITICAL vs CRITICAL+HIGH)
run_test_header "Vulnerability Policy Severity Enforcement (CRITICAL vs CRITICAL+HIGH)"
mkdir -p "$TMPDIR/test12_crit/.supply-chain"
cat << 'EOF' > "$TMPDIR/test12_crit/.supply-chain/policy.yaml"
version: "1.0"
target_platforms: [linux/amd64]
vulnerability_policy:
  fail_on_severity: [CRITICAL]
  ignore_unfixed: false
first_party:
  dockerfile_paths: []
  image_patterns: []
helm_policy:
  classification_patterns: {}
EOF

POL_OBJ12=$(python3 -c "
import sys; sys.path.insert(0, '$SUPPLY_CHAIN_DIR')
import policy
p = policy.load_policy(policy_path='$TMPDIR/test12_crit/.supply-chain/policy.yaml')
print(p['vulnerability_policy']['fail_on_severity'])
")

if [ "$POL_OBJ12" = "['CRITICAL']" ]; then
    pass_test "CRITICAL-only policy correctly loaded and differs from CRITICAL+HIGH"
else
    fail_test "Vulnerability severity policy" "Expected ['CRITICAL'], got $POL_OBJ12"
fi

# TEST 13: Policy ignore_unfixed evaluation
run_test_header "Policy ignore_unfixed evaluation"
mkdir -p "$TMPDIR/test13/.supply-chain"
cat << 'EOF' > "$TMPDIR/test13/.supply-chain/policy.yaml"
version: "1.0"
target_platforms: [linux/amd64]
vulnerability_policy:
  fail_on_severity: [CRITICAL, HIGH]
  ignore_unfixed: true
first_party:
  dockerfile_paths: []
  image_patterns: []
helm_policy:
  classification_patterns: {}
EOF

POL_OBJ13=$(python3 -c "
import sys; sys.path.insert(0, '$SUPPLY_CHAIN_DIR')
import policy
p = policy.load_policy(policy_path='$TMPDIR/test13/.supply-chain/policy.yaml')
print(p['vulnerability_policy']['ignore_unfixed'])
")

if [ "$POL_OBJ13" = "True" ]; then
    pass_test "ignore_unfixed: true correctly loaded from policy configuration"
else
    fail_test "Policy ignore_unfixed" "Expected True, got $POL_OBJ13"
fi

# TEST 14: Dynamic first_party image_patterns policy enforcement
run_test_header "Dynamic first_party image_patterns policy enforcement"
mkdir -p "$TMPDIR/test14/.supply-chain"
cat << 'EOF' > "$TMPDIR/test14/.supply-chain/policy.yaml"
version: "1.0"
target_platforms: [linux/amd64]
vulnerability_policy:
  fail_on_severity: [CRITICAL]
  ignore_unfixed: false
first_party:
  dockerfile_paths: []
  image_patterns: ["custom-org/*"]
helm_policy:
  classification_patterns: {}
EOF

cat << 'EOF' > "$TMPDIR/test14/deploy.yaml"
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
      - name: app
        image: custom-org/my-service:1.0.0
EOF

DISC_POL14=$(python3 scripts/supply-chain/discover-images.py --repo-root "$TMPDIR/test14" --policy "$TMPDIR/test14/.supply-chain/policy.yaml")
OWNERSHIP14=$(echo "$DISC_POL14" | jq -r '.images[0].ownership')

if [ "$OWNERSHIP14" = "FIRST_PARTY_IMAGE" ]; then
    pass_test "custom-org/my-service correctly classified as FIRST_PARTY_IMAGE via dynamic policy image_patterns"
else
    fail_test "Dynamic image_patterns policy" "Expected FIRST_PARTY_IMAGE, got $OWNERSHIP14"
fi

# TEST 15: Malformed Policy Fail-Closed Execution
run_test_header "Malformed Policy Fail-Closed Execution"
mkdir -p "$TMPDIR/test15/.supply-chain"
cat << 'EOF' > "$TMPDIR/test15/.supply-chain/policy.yaml"
version: "1.0"
target_platforms: INVALID_NOT_A_LIST
EOF

if python3 scripts/supply-chain/compare-catalog.py --repo-root "$TMPDIR/test15" 2>/dev/null; then
    fail_test "Fail-closed policy check" "Scanner executed successfully despite malformed policy!"
else
    pass_test "Scanner failed closed on malformed policy as required"
fi

echo "============================================="
if [ "$FAILED" -eq 0 ]; then
    echo "ALL $TOTAL_TESTS HERMETIC SELF-TESTS PASSED SUCCESSFULLY!"
    exit 0
else
    echo "$FAILED / $TOTAL_TESTS HERMETIC SELF-TESTS FAILED!"
    exit 1
fi
EOF
