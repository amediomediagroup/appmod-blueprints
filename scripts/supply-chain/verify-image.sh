#!/usr/bin/env bash
set -euo pipefail

# verify-image.sh
# Usage: ./verify-image.sh <image_ref> [ownership] [policy_path] [output_file]

IMAGE_REF="${1:-}"
OWNERSHIP="${2:-UNKNOWN}"
POLICY_PATH="${3:-}"
OUTPUT_FILE="${4:-}"

if [ -z "$IMAGE_REF" ]; then
    echo "Usage: $0 <image_ref> [ownership] [policy_path] [output_file]" >&2
    exit 1
fi

python3 - "$IMAGE_REF" "$OWNERSHIP" "$POLICY_PATH" "$OUTPUT_FILE" << 'EOF'
import sys
import json
import subprocess
from pathlib import Path

image_ref = sys.argv[1]
ownership = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else "UNKNOWN"
policy_path = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
output_file = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None

script_dir = Path("scripts/supply-chain").resolve()
sys.path.insert(0, str(script_dir))

import policy as policy_module

policy = policy_module.load_policy(policy_path=policy_path)
prov_policy = policy.get("provenance_policy", {})

res = {
    "image": image_ref,
    "ownership": ownership,
    "provenance_status": "UNVERIFIED",
    "signature_verified": False,
    "findings": [],
    "error": None
}

if ownership == "FIRST_PARTY_IMAGE":
    cmd = ["cosign", "verify", "--keyless", image_ref]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode == 0:
        res["provenance_status"] = "VERIFIED"
        res["signature_verified"] = True
    else:
        res["provenance_status"] = "FIRST_PARTY_SIGNATURE_MISSING"
        res["findings"].append({
            "type": "FIRST_PARTY_SIGNATURE_MISSING",
            "message": f"First-party image {image_ref} is missing required Cosign signature"
        })
else:
    # Third party
    cmd = ["cosign", "verify", image_ref]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode == 0:
        res["provenance_status"] = "VERIFIED"
        res["signature_verified"] = True
    else:
        res["provenance_status"] = "UPSTREAM_PROVENANCE_UNVERIFIED"
        res["findings"].append({
            "type": "UPSTREAM_PROVENANCE_UNVERIFIED",
            "message": f"Third-party image {image_ref} upstream provenance/signature is unverified"
        })

out_str = json.dumps(res, indent=2)
if output_file:
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write(out_str)
else:
    print(out_str)

EOF
