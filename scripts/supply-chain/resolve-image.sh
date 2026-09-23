#!/usr/bin/env bash
set -euo pipefail

# resolve-image.sh
# Usage: ./resolve-image.sh <image_ref> [output_file]

IMAGE_REF="${1:-}"
OUTPUT_FILE="${2:-}"

if [ -z "$IMAGE_REF" ]; then
    echo "Usage: $0 <image_ref> [output_file]" >&2
    exit 1
fi

python3 - "$IMAGE_REF" "$OUTPUT_FILE" << 'EOF'
import sys
import json
import subprocess
import hashlib

image_ref = sys.argv[1]
output_file = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None

res = {
    "image": image_ref,
    "top_level_digest": None,
    "is_multi_platform": False,
    "platforms": {
        "linux/amd64": {
            "digest": None,
            "available": False
        },
        "linux/arm64": {
            "digest": None,
            "available": False
        }
    },
    "findings": [],
    "error": None
}

try:
    # 1. Inspect top level raw manifest
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

        # Try skopeo inspect to get top-level canonical digest if available
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
            # Check if index / manifest list
            if "manifests" in manifest_data and isinstance(manifest_data["manifests"], list):
                res["is_multi_platform"] = True
                for m in manifest_data["manifests"]:
                    platform = m.get("platform", {})
                    arch = platform.get("architecture")
                    os_name = platform.get("os")
                    digest = m.get("digest")

                    if os_name == "linux" and arch == "amd64":
                        res["platforms"]["linux/amd64"]["digest"] = digest
                        res["platforms"]["linux/amd64"]["available"] = True
                    elif os_name == "linux" and arch == "arm64":
                        res["platforms"]["linux/arm64"]["digest"] = digest
                        res["platforms"]["linux/arm64"]["available"] = True
            else:
                # Single platform
                res["is_multi_platform"] = False
                # Use skopeo inspect to get arch
                if proc_insp.returncode == 0:
                    insp_json = json.loads(proc_insp.stdout)
                    arch = insp_json.get("Architecture")
                    os_name = insp_json.get("Os", "linux")
                    if os_name == "linux" and arch == "amd64":
                        res["platforms"]["linux/amd64"]["digest"] = top_digest
                        res["platforms"]["linux/amd64"]["available"] = True
                    elif os_name == "linux" and arch == "arm64":
                        res["platforms"]["linux/arm64"]["digest"] = top_digest
                        res["platforms"]["linux/arm64"]["available"] = True
        except Exception as e:
            res["error"] = f"Failed to parse raw manifest: {e}"

    # Evaluate missing platform findings
    if not res["platforms"]["linux/amd64"]["available"]:
        res["findings"].append({
            "type": "PLATFORM_AMD64_MISSING",
            "message": f"Image {image_ref} is missing required linux/amd64 artifact"
        })
    if not res["platforms"]["linux/arm64"]["available"]:
        res["findings"].append({
            "type": "PLATFORM_ARM64_MISSING",
            "message": f"Image {image_ref} is missing required linux/arm64 artifact"
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
