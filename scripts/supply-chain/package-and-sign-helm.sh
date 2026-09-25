#!/usr/bin/env bash
set -euo pipefail

# package-and-sign-helm.sh
# Packages, pushes, and Cosign-signs Helm charts to GHCR OCI registry.
# Usage: ./package-and-sign-helm.sh <chart_dir> [mode: first-party|mirror] [vendor_namespace] [policy_path] [output_file]

CHART_DIR="${1:-}"
MODE="${2:-first-party}"
VENDOR_NS="${3:-}"
POLICY_PATH="${4:-}"
OUTPUT_FILE="${5:-}"

if [ -z "$CHART_DIR" ] || [ ! -f "$CHART_DIR/Chart.yaml" ]; then
    echo "Usage: $0 <chart_dir> [mode: first-party|mirror] [vendor_namespace] [policy_path] [output_file]" >&2
    exit 1
fi

python3 - "$CHART_DIR" "$MODE" "$VENDOR_NS" "$POLICY_PATH" "$OUTPUT_FILE" << 'EOF'
import sys
import os
import json
import subprocess
import tempfile
from pathlib import Path
import yaml

chart_dir = Path(sys.argv[1]).resolve()
mode = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else "first-party"
vendor_ns = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else ""
policy_path = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None
output_file = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else None

script_dir = Path(os.environ.get("SUPPLY_CHAIN_DIR", "scripts/supply-chain")).resolve()
if not (script_dir / "policy.py").exists():
    script_dir = Path(__file__).resolve().parent
sys.path.insert(0, str(script_dir))

import policy as policy_module

policy = policy_module.load_policy(policy_path=policy_path)
registries = policy["registries"]
prov_policy = policy.get("provenance_policy", {})

with open(chart_dir / "Chart.yaml", "r", encoding="utf-8") as f:
    chart_yaml = yaml.safe_load(f) or {}

chart_name = chart_yaml.get("name")
chart_version = chart_yaml.get("version")

if mode == "mirror" and vendor_ns:
    oci_base = f"{registries['helm_upstream_mirror_registry']}/{vendor_ns}"
else:
    oci_base = registries['helm_oci_registry']

target_oci_repo = f"oci://{oci_base}"
full_oci_ref = f"{oci_base}/{chart_name}:{chart_version}"

res = {
    "chart_name": chart_name,
    "version": chart_version,
    "mode": mode,
    "oci_reference": full_oci_ref,
    "oci_digest": None,
    "signature_verified": False,
    "provenance_status": "UNVERIFIED",
    "error": None
}

with tempfile.TemporaryDirectory() as tmpdir:
    pkg_dir = Path(tmpdir)

    # 1. Dependency build if needed (fail closed on error)
    if chart_yaml.get("dependencies"):
        cmd_dep = ["helm", "dependency", "build", str(chart_dir)]
        proc_dep = subprocess.run(cmd_dep, capture_output=True, text=True)
        if proc_dep.returncode != 0:
            raise RuntimeError(f"Helm dependency build failed for {chart_name}: {proc_dep.stderr.strip()}")

    # 2. Helm Lint (fail closed on error)
    cmd_lint = ["helm", "lint", str(chart_dir)]
    proc_lint = subprocess.run(cmd_lint, capture_output=True, text=True)
    if proc_lint.returncode != 0:
        raise RuntimeError(f"Helm lint failed for {chart_name}: {proc_lint.stderr.strip()}")

    # 3. Helm Package (fail closed on error)
    cmd_pkg = ["helm", "package", str(chart_dir), "-d", str(pkg_dir)]
    proc_pkg = subprocess.run(cmd_pkg, capture_output=True, text=True)

    if proc_pkg.returncode != 0:
        raise RuntimeError(f"Helm package failed for {chart_name}: {proc_pkg.stderr.strip()}")

    pkg_files = list(pkg_dir.glob("*.tgz"))
    if not pkg_files:
        raise RuntimeError(f"No packaged .tgz file found for {chart_name}")

    pkg_file = pkg_files[0]

    # 4. Helm Push (fail closed on error)
    cmd_push = ["helm", "push", str(pkg_file), target_oci_repo]
    proc_push = subprocess.run(cmd_push, capture_output=True, text=True)

    if proc_push.returncode != 0:
        raise RuntimeError(f"Helm push failed for {chart_name}: {proc_push.stderr.strip()}")

    # 5. Resolve OCI Digest via Skopeo
    cmd_dig = ["skopeo", "inspect", f"docker://{full_oci_ref}"]
    proc_dig = subprocess.run(cmd_dig, capture_output=True, text=True)
    if proc_dig.returncode != 0:
        raise RuntimeError(f"Digest resolution failed for {full_oci_ref}: {proc_dig.stderr.strip()}")

    try:
        dig_json = json.loads(proc_dig.stdout)
        res["oci_digest"] = dig_json.get("Digest")
    except Exception as e:
        raise RuntimeError(f"Failed to parse digest for {full_oci_ref}: {e}")

    if not res["oci_digest"]:
        raise RuntimeError(f"Resolved empty OCI digest for {full_oci_ref}")

    # 6. Cosign Keyless Sign & Verify Immutable Digest
    sign_target = f"{oci_base}/{chart_name}@{res['oci_digest']}"
    first_party_prov = prov_policy.get("first_party", {})
    cert_id_regex = first_party_prov.get("expected_certificate_identity_regexp") or first_party_prov.get("expected_certificate_identity")
    oidc_issuer = first_party_prov.get("expected_oidc_issuer")

    if not cert_id_regex or not oidc_issuer:
        raise RuntimeError("Missing expected_certificate_identity_regexp or expected_oidc_issuer in policy")

    cmd_sign = ["cosign", "sign", "--yes", sign_target]
    proc_sign = subprocess.run(cmd_sign, capture_output=True, text=True)
    if proc_sign.returncode != 0:
        raise RuntimeError(f"Cosign sign failed for {sign_target}: {proc_sign.stderr.strip()}")

    cmd_ver = [
        "cosign", "verify",
        "--certificate-identity-regexp", cert_id_regex,
        "--certificate-oidc-issuer", oidc_issuer,
        sign_target
    ]
    proc_ver = subprocess.run(cmd_ver, capture_output=True, text=True)
    if proc_ver.returncode != 0:
        raise RuntimeError(f"Cosign verify failed for {sign_target}: {proc_ver.stderr.strip()}")

    res["signature_verified"] = True
    res["provenance_status"] = "VERIFIED_PRODUCER" if mode == "first-party" else "AEGIS_IMPORTED_AND_APPROVED"

out_str = json.dumps(res, indent=2)
if output_file:
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write(out_str)
else:
    print(out_str)

EOF
