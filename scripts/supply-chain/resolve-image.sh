#!/usr/bin/env bash
set -euo pipefail

# resolve-image.sh
# Usage: ./resolve-image.sh <image_ref> [policy_path] [output_file]

IMAGE_REF="${1:-}"
POLICY_PATH="${2:-}"
OUTPUT_FILE="${3:-}"

if [ -z "$IMAGE_REF" ]; then
    echo "Usage: $0 <image_ref> [policy_path] [output_file]" >&2
    exit 1
fi

python3 - "$IMAGE_REF" "$POLICY_PATH" "$OUTPUT_FILE" << 'EOF'
import sys
import json
import subprocess
import hashlib
from pathlib import Path

image_ref = sys.argv[1]
policy_path = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None
output_file = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None

import os
script_dir = Path(os.environ.get("SUPPLY_CHAIN_DIR", "scripts/supply-chain")).resolve()
if not (script_dir / "policy.py").exists():
    script_dir = Path(__file__).resolve().parent
sys.path.insert(0, str(script_dir))

import policy as policy_module

policy = policy_module.load_policy(policy_path=policy_path)
target_platforms = policy["target_platforms"]

res = {
    "image": image_ref,
    "top_level_digest": None,
    "is_multi_platform": False,
    "platforms": {plat: {"digest": None, "available": False} for plat in target_platforms},
    "findings": [],
    "error": None
}

try:
    cmd_raw = ["skopeo", "inspect", "--raw", f"docker://{image_ref}"]
    proc_raw = subprocess.run(cmd_raw, capture_output=True, text=True)

    if proc_raw.returncode != 0:
        res["error"] = proc_raw.stderr.strip()
        res["findings"].append({
            "type": "IMAGE_DIGEST_MISSING",
            "message": f"Failed to resolve digest for {image_ref}: {proc_raw.stderr.strip()}"
        })
    else:
        raw_manifest_str = proc_raw.stdout
        top_digest = "sha256:" + hashlib.sha256(raw_manifest_str.encode('utf-8')).hexdigest()

        cmd_insp = ["skopeo", "inspect", f"docker://{image_ref}"]
        proc_insp = subprocess.run(cmd_insp, capture_output=True, text=True)
        if proc_insp.returncode == 0:
            try:
                insp_json = json.loads(proc_insp.stdout)
                if insp_json.get("Digest"):
                    top_digest = insp_json["Digest"]
            except Exception:
                pass

        res["top_level_digest"] = top_digest

        try:
            manifest_data = json.loads(raw_manifest_str)
            if "manifests" in manifest_data and isinstance(manifest_data["manifests"], list):
                res["is_multi_platform"] = True
                for m in manifest_data["manifests"]:
                    platform_info = m.get("platform", {})
                    arch = platform_info.get("architecture")
                    os_name = platform_info.get("os")
                    digest = m.get("digest")

                    plat_key = f"{os_name}/{arch}"
                    if plat_key in res["platforms"]:
                        res["platforms"][plat_key]["digest"] = digest
                        res["platforms"][plat_key]["available"] = True
            else:
                res["is_multi_platform"] = False
                if proc_insp.returncode == 0:
                    insp_json = json.loads(proc_insp.stdout)
                    arch = insp_json.get("Architecture")
                    os_name = insp_json.get("Os", "linux")
                    plat_key = f"{os_name}/{arch}"
                    if plat_key in res["platforms"]:
                        res["platforms"][plat_key]["digest"] = top_digest
                        res["platforms"][plat_key]["available"] = True
        except Exception as e:
            res["error"] = f"Failed to parse raw manifest: {e}"

    for plat in target_platforms:
        if not res["platforms"][plat]["available"]:
            arch_label = "AMD64" if "amd64" in plat else "ARM64"
            res["findings"].append({
                "type": f"PLATFORM_{arch_label}_MISSING",
                "message": f"Image {image_ref} is missing required {plat} artifact"
            })

except Exception as ex:
    res["error"] = str(ex)

out_str = json.dumps(res, indent=2)
if output_file:
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write(out_str)
else:
    print(out_str)

EOF
