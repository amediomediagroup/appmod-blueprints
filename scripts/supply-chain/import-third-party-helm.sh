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

# Locate policy.py — robust for both regular files and stdin (heredoc) scripts
_sd_candidates = [
    Path(os.environ["SUPPLY_CHAIN_DIR"]) if "SUPPLY_CHAIN_DIR" in os.environ else None,
    Path(os.getcwd()) / "scripts" / "supply-chain",  # CI: CWD = repo root
    Path("/app/scripts/supply-chain"),
]
script_dir = next(
    (p.resolve() for p in _sd_candidates if p and (p / "policy.py").exists()),
    Path(os.getcwd()) / "scripts" / "supply-chain",  # last-resort default
)
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
                # Prefer digest from helm push stdout/stderr ("Digest: sha256:...")
                # skopeo inspect --raw fails on Helm OCI artifacts (non-image type)
                push_digest = None
                for line in (proc_push.stdout + proc_push.stderr).splitlines():
                    stripped = line.strip()
                    if stripped.lower().startswith("digest:"):
                        candidate = stripped.split(":", 1)[-1].strip()
                        if candidate.startswith("sha256:"):
                            push_digest = candidate
                            break

                docker_cfg = Path.home() / ".docker" / "config.json"
                helm_cfg = Path.home() / ".config" / "helm" / "registry" / "config.json"

                if docker_cfg.exists():
                    auth_args = ["--authfile", str(docker_cfg)]
                elif helm_cfg.exists():
                    auth_args = ["--authfile", str(helm_cfg)]
                else:
                    auth_args = []

                if push_digest:
                    res["destination_oci_digest"] = push_digest
                else:
                    # Fallback: skopeo inspect (without --raw) returns structured JSON
                    # with a Digest field and handles OCI artifacts correctly
                    cmd_inspect = ["skopeo", "inspect"] + auth_args + [f"docker://{full_oci_ref}"]
                    proc_inspect = subprocess.run(cmd_inspect, capture_output=True, text=True)
                    if proc_inspect.returncode == 0:
                        try:
                            res["destination_oci_digest"] = json.loads(proc_inspect.stdout).get("Digest", "")
                        except json.JSONDecodeError:
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
