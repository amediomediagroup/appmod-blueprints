#!/usr/bin/env bash
set -euo pipefail

# verify-image.sh
# Usage: ./verify-image.sh <image_ref> <ownership> [output_file]
# ownership: FIRST_PARTY_IMAGE or THIRD_PARTY_IMAGE or UNKNOWN

IMAGE_REF="${1:-}"
OWNERSHIP="${2:-UNKNOWN}"
OUTPUT_FILE="${3:-}"

if [ -z "$IMAGE_REF" ]; then
    echo "Usage: $0 <image_ref> <ownership> [output_file]" >&2
    exit 1
fi

python3 - "$IMAGE_REF" "$OWNERSHIP" "$OUTPUT_FILE" << 'EOF'
import sys
import json
import subprocess

image_ref = sys.argv[1]
ownership = sys.argv[2]
output_file = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None

res = {
    "image": image_ref,
    "ownership": ownership,
    "provenance_status": "UNVERIFIED",
    "signature_verified": False,
    "findings": [],
    "error": None
}

if ownership == "FIRST_PARTY_IMAGE":
    # For first party, run cosign verify
    # (Without public key or keyless setup, cosign verify-attestation or cosign verify checks signature)
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
    # Try verifying upstream signature if cosign supports keyless/public certs for upstream
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
