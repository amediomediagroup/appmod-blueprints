#!/usr/bin/env bash
set -euo pipefail

# scan-image.sh
# Usage: ./scan-image.sh <image_ref> <platform> [digest] [output_file]
# platform: linux/amd64 or linux/arm64

IMAGE_REF="${1:-}"
PLATFORM="${2:-linux/amd64}"
DIGEST="${3:-}"
OUTPUT_FILE="${4:-}"

if [ -z "$IMAGE_REF" ]; then
    echo "Usage: $0 <image_ref> <platform> [digest] [output_file]" >&2
    exit 1
fi

python3 - "$IMAGE_REF" "$PLATFORM" "$DIGEST" "$OUTPUT_FILE" << 'EOF'
import sys
import json
import os
import subprocess
import tempfile

image_ref = sys.argv[1]
platform = sys.argv[2]
digest = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
output_file = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None

arch_name = "amd64" if "amd64" in platform else "arm64"

res = {
    "image": image_ref,
    "platform": platform,
    "digest": digest,
    "sbom_status": "MISSING",
    "vulnerability_status": "UNSCANNED",
    "critical_count": 0,
    "high_count": 0,
    "medium_count": 0,
    "low_count": 0,
    "findings": [],
    "error": None
}

target = f"{image_ref}@{digest}" if digest else image_ref

with tempfile.TemporaryDirectory() as tmpdir:
    sbom_file = os.path.join(tmpdir, "sbom.json")
    grype_file = os.path.join(tmpdir, "grype.json")

    # 1. Syft SBOM generation
    syft_cmd = ["syft", f"registry:{target}", f"--platform={platform}", "-o", f"json={sbom_file}"]
    proc_syft = subprocess.run(syft_cmd, capture_output=True, text=True)

    if proc_syft.returncode != 0 or not os.path.exists(sbom_file):
        res["error"] = proc_syft.stderr.strip()
        finding_type = "SBOM_AMD64_MISSING" if arch_name == "amd64" else "SBOM_ARM64_MISSING"
        res["findings"].append({
            "type": finding_type,
            "message": f"Failed to generate SBOM for {target} ({platform}): {proc_syft.stderr.strip()}"
        })
    else:
        res["sbom_status"] = "PRESENT"

        # 2. Grype scan SBOM
        grype_cmd = ["grype", f"sbom:{sbom_file}", "-o", "json"]
        proc_grype = subprocess.run(grype_cmd, capture_output=True, text=True)

        if proc_grype.returncode != 0 and not proc_grype.stdout:
            res["error"] = proc_grype.stderr.strip()
        else:
            try:
                grype_data = json.loads(proc_grype.stdout)
                matches = grype_data.get("matches", [])
                for match in matches:
                    sev = match.get("vulnerability", {}).get("severity", "").upper()
                    if sev == "CRITICAL":
                        res["critical_count"] += 1
                    elif sev == "HIGH":
                        res["high_count"] += 1
                    elif sev == "MEDIUM":
                        res["medium_count"] += 1
                    elif sev == "LOW":
                        res["low_count"] += 1

                if res["critical_count"] > 0 or res["high_count"] > 0:
                    res["vulnerability_status"] = "EXCEEDED"
                    finding_type = "VULNERABILITY_AMD64_THRESHOLD_EXCEEDED" if arch_name == "amd64" else "VULNERABILITY_ARM64_THRESHOLD_EXCEEDED"
                    res["findings"].append({
                        "type": finding_type,
                        "message": f"Vulnerability threshold exceeded for {target} ({platform}): {res['critical_count']} CRITICAL, {res['high_count']} HIGH"
                    })
                else:
                    res["vulnerability_status"] = "CLEAN"

            except Exception as ex:
                res["error"] = f"Failed to parse Grype output: {ex}"

out_str = json.dumps(res, indent=2)
if output_file:
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write(out_str)
else:
    print(out_str)

EOF
