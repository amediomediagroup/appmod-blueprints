#!/usr/bin/env bash
set -euo pipefail

# scan-image.sh
# Usage: ./scan-image.sh <image_ref> [platform] [digest] [policy_path] [output_file]

IMAGE_REF="${1:-}"
PLATFORM="${2:-linux/amd64}"
DIGEST="${3:-}"
POLICY_PATH="${4:-}"
OUTPUT_FILE="${5:-}"

if [ -z "$IMAGE_REF" ]; then
    echo "Usage: $0 <image_ref> [platform] [digest] [policy_path] [output_file]" >&2
    exit 1
fi

python3 - "$IMAGE_REF" "$PLATFORM" "$DIGEST" "$POLICY_PATH" "$OUTPUT_FILE" << 'EOF'
import sys
import json
import os
import subprocess
import tempfile
from pathlib import Path

image_ref = sys.argv[1]
platform = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else "linux/amd64"
digest = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
policy_path = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None
output_file = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else None

script_dir = Path(os.environ.get("SUPPLY_CHAIN_DIR", "scripts/supply-chain")).resolve()
if not (script_dir / "policy.py").exists():
    script_dir = Path(__file__).resolve().parent
sys.path.insert(0, str(script_dir))

import policy as policy_module

policy = policy_module.load_policy(policy_path=policy_path)
fail_severities = set(policy["vulnerability_policy"]["fail_on_severity"])
ignore_unfixed = policy["vulnerability_policy"]["ignore_unfixed"]

arch_name = "amd64" if "amd64" in platform else "arm64"

res = {
    "image": image_ref,
    "platform": platform,
    "digest": digest,
    "sbom_status": "MISSING",
    "vulnerability_status": "UNSCANNED",
    "severity_counts": {},
    "exceeded_vulnerabilities": 0,
    "findings": [],
    "error": None
}

target = f"{image_ref}@{digest}" if digest else image_ref

with tempfile.TemporaryDirectory() as tmpdir:
    sbom_file = os.path.join(tmpdir, "sbom.json")

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

                exceeded_count = 0
                for match in matches:
                    vuln = match.get("vulnerability", {})
                    sev = vuln.get("severity", "").upper()
                    fix_state = match.get("vulnerability", {}).get("fix", {}).get("state", "")

                    if ignore_unfixed and fix_state in ["not-fixed", "unfixed", "wont-fix"]:
                        continue

                    res["severity_counts"][sev] = res["severity_counts"].get(sev, 0) + 1

                    if sev in fail_severities:
                        exceeded_count += 1

                res["exceeded_vulnerabilities"] = exceeded_count

                if exceeded_count > 0:
                    res["vulnerability_status"] = "EXCEEDED"
                    finding_type = "VULNERABILITY_AMD64_THRESHOLD_EXCEEDED" if arch_name == "amd64" else "VULNERABILITY_ARM64_THRESHOLD_EXCEEDED"
                    res["findings"].append({
                        "type": finding_type,
                        "message": f"Vulnerability threshold exceeded for {target} ({platform}): {exceeded_count} vulnerabilities matching policy fail_on_severity {list(fail_severities)}"
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
