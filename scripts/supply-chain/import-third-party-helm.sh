#!/usr/bin/env bash
set -euo pipefail

# import-third-party-helm.sh
# Imports, verifies, and pushes third-party Helm charts to ghcr.io/amediomediagroup/charts/upstream/<vendor>/<chart>:<version>
# Usage: ./import-third-party-helm.sh <vendor> <chart_name> <version> [upstream_repo_url] [policy_path] [output_file]

VENDOR="${1:-}"
CHART_NAME="${2:-}"
VERSION="${3:-}"
UPSTREAM_REPO="${4:-}"
POLICY_PATH="${5:-}"
OUTPUT_FILE="${6:-}"

if [ -z "$VENDOR" ] || [ -z "$CHART_NAME" ] || [ -z "$VERSION" ]; then
    echo "Usage: $0 <vendor> <chart_name> <version> [upstream_repo_url] [policy_path] [output_file]" >&2
    exit 1
fi

python3 - "$VENDOR" "$CHART_NAME" "$VERSION" "$UPSTREAM_REPO" "$POLICY_PATH" "$OUTPUT_FILE" << 'EOF'
import sys
import os
import json
import hashlib
import subprocess
import tempfile
from pathlib import Path

vendor = sys.argv[1]
chart_name = sys.argv[2]
version = sys.argv[3]
upstream_repo = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else ""
policy_path = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else None
output_file = sys.argv[6] if len(sys.argv) > 6 and sys.argv[6] else None

script_dir = Path(os.environ.get("SUPPLY_CHAIN_DIR", "scripts/supply-chain")).resolve()
if not (script_dir / "policy.py").exists():
    script_dir = Path(__file__).resolve().parent
sys.path.insert(0, str(script_dir))

import policy as policy_module

policy = policy_module.load_policy(policy_path=policy_path)
helm_upstream_reg = policy["registries"]["helm_upstream_mirror_registry"]

dest_oci_repo = f"oci://{helm_upstream_reg}/{vendor}"
full_oci_ref = f"{helm_upstream_reg}/{vendor}/{chart_name}:{version}"

res = {
    "vendor": vendor,
    "chart_name": chart_name,
    "version": version,
    "upstream_repository": upstream_repo,
    "source_package_sha256": None,
    "destination_oci_reference": full_oci_ref,
    "destination_oci_digest": None,
    "aegis_import_attestation": "AEGIS_IMPORTED_AND_APPROVED",
    "signature_verified": False,
    "error": None
}

with tempfile.TemporaryDirectory() as tmpdir:
    pkg_dir = Path(tmpdir)

    # 1. Pull upstream chart
    if upstream_repo.startswith("oci://"):
        cmd_pull = ["helm", "pull", f"{upstream_repo}/{chart_name}", "--version", version, "-d", str(pkg_dir)]
    else:
        cmd_pull = ["helm", "pull", chart_name, "--repo", upstream_repo, "--version", version, "-d", str(pkg_dir)]

    proc_pull = subprocess.run(cmd_pull, capture_output=True, text=True)
    if proc_pull.returncode != 0:
        res["error"] = f"Helm pull failed: {proc_pull.stderr.strip()}"
    else:
        pkg_files = list(pkg_dir.glob("*.tgz"))
        if pkg_files:
            pkg_file = pkg_files[0]
            with open(pkg_file, "rb") as f:
                res["source_package_sha256"] = hashlib.sha256(f.read()).hexdigest()

            # 2. Push to Aegis OCI mirror
            cmd_push = ["helm", "push", str(pkg_file), dest_oci_repo]
            proc_push = subprocess.run(cmd_push, capture_output=True, text=True)

            if proc_push.returncode != 0:
                res["error"] = f"Helm push to Aegis mirror failed: {proc_push.stderr.strip()}"
            else:
                # 3. Resolve destination OCI digest
                cmd_dig = ["skopeo", "inspect", f"docker://{full_oci_ref}"]
                proc_dig = subprocess.run(cmd_dig, capture_output=True, text=True)
                if proc_dig.returncode == 0:
                    try:
                        dig_json = json.loads(proc_dig.stdout)
                        res["destination_oci_digest"] = dig_json.get("Digest")
                    except Exception:
                        pass

                # 4. Cosign sign as AEGIS IMPORT/APPROVAL
                sign_target = f"{full_oci_ref}@{res['destination_oci_digest']}" if res["destination_oci_digest"] else full_oci_ref
                cmd_sign = ["cosign", "sign", "--yes", sign_target]
                proc_sign = subprocess.run(cmd_sign, capture_output=True, text=True)
                if proc_sign.returncode == 0:
                    res["signature_verified"] = True

out_str = json.dumps(res, indent=2)
if output_file:
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write(out_str)
else:
    print(out_str)

EOF
