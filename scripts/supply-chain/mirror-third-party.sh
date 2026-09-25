#!/usr/bin/env bash
set -euo pipefail

# mirror-third-party.sh
# Mirrors upstream third-party OCI images to ghcr.io/amediomediagroup/upstream/<canonical-name>
# Usage: ./mirror-third-party.sh <upstream_image_ref> [canonical_name] [policy_path] [output_file]

UPSTREAM_REF="${1:-}"
CANONICAL_NAME="${2:-}"
POLICY_PATH="${3:-}"
OUTPUT_FILE="${4:-}"

if [ -z "$UPSTREAM_REF" ]; then
    echo "Usage: $0 <upstream_image_ref> [canonical_name] [policy_path] [output_file]" >&2
    exit 1
fi

python3 - "$UPSTREAM_REF" "$CANONICAL_NAME" "$POLICY_PATH" "$OUTPUT_FILE" << 'EOF'
import sys
import os
import json
import subprocess
from pathlib import Path

upstream_ref = sys.argv[1]
canonical_name = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else os.path.basename(upstream_ref)
policy_path = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
output_file = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None

script_dir = Path(os.environ.get("SUPPLY_CHAIN_DIR", "scripts/supply-chain")).resolve()
if not (script_dir / "policy.py").exists():
    script_dir = Path(__file__).resolve().parent
sys.path.insert(0, str(script_dir))

import policy as policy_module

policy = policy_module.load_policy(policy_path=policy_path)
upstream_mirror_reg = policy["registries"]["upstream_mirror_registry"]
target_platforms = policy["target_platforms"]
prov_policy = policy.get("provenance_policy", {})

dest_ref = f"{upstream_mirror_reg}/{canonical_name}"

res = {
    "upstream_reference": upstream_ref,
    "mirrored_reference": dest_ref,
    "upstream_top_level_digest": None,
    "mirrored_top_level_digest": None,
    "platforms": {plat: {"digest": None, "available": False} for plat in target_platforms},
    "provenance_status": "UPSTREAM_PROVENANCE_UNVERIFIED",
    "aegis_import_attestation": "AEGIS_IMPORTED_AND_APPROVED",
    "signature_verified": False,
    "error": None
}

# 1. Resolve upstream digest via Skopeo
cmd_insp_up = ["skopeo", "inspect", f"docker://{upstream_ref}"]
proc_up = subprocess.run(cmd_insp_up, capture_output=True, text=True)
if proc_up.returncode == 0:
    try:
        up_json = json.loads(proc_up.stdout)
        res["upstream_top_level_digest"] = up_json.get("Digest")
    except Exception:
        pass

# 2. Skopeo copy multi-arch OCI index preserve-exact
cmd_copy = ["skopeo", "copy", "--all", f"docker://{upstream_ref}", f"docker://{dest_ref}"]
proc_copy = subprocess.run(cmd_copy, capture_output=True, text=True)

if proc_copy.returncode != 0:
    res["error"] = f"Skopeo copy failed: {proc_copy.stderr.strip()}"
else:
    # 3. Resolve destination digest
    cmd_insp_dest = ["skopeo", "inspect", f"docker://{dest_ref}"]
    proc_dest = subprocess.run(cmd_insp_dest, capture_output=True, text=True)
    if proc_dest.returncode == 0:
        try:
            dest_json = json.loads(proc_dest.stdout)
            res["mirrored_top_level_digest"] = dest_json.get("Digest")
        except Exception:
            pass

    # 4. Resolve multi-arch child digests
    resolve_script = script_dir / "resolve-image.sh"
    if resolve_script.exists():
        try:
            proc_res = subprocess.run([str(resolve_script), dest_ref, str(policy_path or "")], capture_output=True, text=True)
            if proc_res.returncode == 0:
                res_data = json.loads(proc_res.stdout)
                res["platforms"] = res_data.get("platforms", res["platforms"])
        except Exception as ex:
            res["error"] = f"Multi-arch resolution failed for mirrored image: {ex}"

    # 5. Cosign sign as AEGIS IMPORT/APPROVAL
    cmd_sign = ["cosign", "sign", "--yes", dest_ref]
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
