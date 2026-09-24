#!/usr/bin/env python3
"""
compare-catalog.py

Compares current codebase artifacts (discovered images and Helm charts)
against the canonical catalog (.supply-chain/artifacts.yaml) and policy (.supply-chain/policy.yaml).

Generates deterministic findings for:
- NEW_IMAGE
- NEW_DOCKERFILE
- NEW_HELM_CHART
- UNCATALOGUED_ARTIFACT
- UNRESOLVED_DYNAMIC_IMAGE
- MUTABLE_TAG
- MUTABLE_TAG_DRIFT
- IMAGE_DIGEST_MISSING
- PLATFORM_AMD64_MISSING
- PLATFORM_ARM64_MISSING
- PLATFORM_DIGEST_DRIFT
- SBOM_AMD64_MISSING
- SBOM_ARM64_MISSING
- VULNERABILITY_AMD64_THRESHOLD_EXCEEDED
- VULNERABILITY_ARM64_THRESHOLD_EXCEEDED
- UPSTREAM_PROVENANCE_UNVERIFIED
- FIRST_PARTY_SIGNATURE_MISSING
- HELM_LOCK_DRIFT
- HELM_OCI_MISSING
- HELM_OCI_TAG_MUTATED
"""

import os
import sys
import json
import argparse
import subprocess
from pathlib import Path
import yaml

def load_yaml(filepath: Path):
    if not filepath.exists():
        return {}
    with open(filepath, 'r', encoding='utf-8') as f:
        return yaml.safe_load(f) or {}

def save_yaml(filepath: Path, data: dict):
    filepath.parent.mkdir(parents=True, exist_ok=True)
    with open(filepath, 'w', encoding='utf-8') as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False)

def main():
    parser = argparse.ArgumentParser(description="Compare catalog against current repository state.")
    parser.add_argument("--repo-root", default=".", help="Repository root directory")
    parser.add_argument("--catalog", default=".supply-chain/artifacts.yaml", help="Path to catalog YAML")
    parser.add_argument("--policy", default=".supply-chain/policy.yaml", help="Path to policy YAML")
    parser.add_argument("--update-catalog", action="store_true", help="Update catalog file with current state")
    parser.add_argument("--scan", action="store_true", help="Perform online OCI resolution, SBOM generation, vulnerability scanning, and provenance verification")
    parser.add_argument("--output", default=None, help="Output JSON file path for findings")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    script_dir = Path(__file__).parent.resolve()

    catalog_path = repo_root / args.catalog
    policy_path = repo_root / args.policy

    catalog = load_yaml(catalog_path)
    policy = load_yaml(policy_path)

    catalog_images_map = {img['image']: img for img in catalog.get('images', [])}
    catalog_charts_map = {c['source_path']: c for c in catalog.get('helm_charts', [])}

    sys.path.insert(0, str(script_dir))
    import importlib.util

    disc_img_path = script_dir / "discover-images.py"
    if not disc_img_path.exists():
        disc_img_path = repo_root / "scripts" / "supply-chain" / "discover-images.py"

    spec_img = importlib.util.spec_from_file_location("discover_images", disc_img_path)
    discover_images = importlib.util.module_from_spec(spec_img)
    spec_img.loader.exec_module(discover_images)

    disc_helm_path = script_dir / "discover-helm.py"
    if not disc_helm_path.exists():
        disc_helm_path = repo_root / "scripts" / "supply-chain" / "discover-helm.py"

    spec_helm = importlib.util.spec_from_file_location("discover_helm", disc_helm_path)
    discover_helm = importlib.util.module_from_spec(spec_helm)
    spec_helm.loader.exec_module(discover_helm)

    discovered_images, dockerfile_list, unresolved_dynamic_images = discover_images.discover_all(repo_root)
    discovered_charts = discover_helm.discover_helm_charts(repo_root)

    findings = []
    updated_catalog_images = []
    updated_catalog_charts = []

    # 0. Process UNRESOLVED_DYNAMIC_IMAGE findings
    for unres in unresolved_dynamic_images:
        sp = unres.get('source_path', '')
        f = {
            "type": "UNRESOLVED_DYNAMIC_IMAGE",
            "artifact": unres.get('image', ''),
            "source_paths": [sp] if sp else [],
            "evidence": {
                "source_path": sp,
                "variable_name": unres.get('variable_name', ''),
                "from_expression": unres.get('from_expression', ''),
                "line": unres.get('line'),
                "context": unres.get('context', '')
            }
        }
        findings.append(f)

    # 1. Audit Helm Charts & Compare Catalog
    for chart in discovered_charts:
        sp = chart['source_path']

        if sp not in catalog_charts_map:
            f = {
                "type": "NEW_HELM_CHART",
                "artifact": chart['chart_name'],
                "source_paths": [sp],
                "evidence": {
                    "source_path": sp,
                    "classification": chart['classification'],
                    "version": chart['version']
                }
            }
            findings.append(f)

            f_uncat = {
                "type": "UNCATALOGUED_ARTIFACT",
                "artifact": chart['chart_name'],
                "source_paths": [sp],
                "evidence": {
                    "source_path": sp,
                    "artifact_type": "HELM_CHART"
                }
            }
            findings.append(f_uncat)

        if chart['chart_lock_state'] == "MISSING":
            f = {
                "type": "HELM_LOCK_DRIFT",
                "artifact": chart['chart_name'],
                "source_paths": [sp],
                "evidence": {
                    "source_path": sp,
                    "reason": "Dependencies declared in Chart.yaml but Chart.lock is missing"
                }
            }
            findings.append(f)

        if chart['classification'] == "RELEASE_ARTIFACT_OCI_CANDIDATE":
            prev_entry = catalog_charts_map.get(sp, {})
            known_digest = prev_entry.get('known_oci_digest') or chart.get('known_oci_digest')
            if not known_digest:
                f = {
                    "type": "HELM_OCI_MISSING",
                    "artifact": chart['chart_name'],
                    "source_paths": [sp],
                    "evidence": {
                        "source_path": sp,
                        "classification": chart['classification'],
                        "reason": "Missing OCI release digest for OCI candidate chart"
                    }
                }
                findings.append(f)

        updated_catalog_charts.append({
            "source_path": sp,
            "chart_name": chart['chart_name'],
            "version": chart['version'],
            "classification": chart['classification'],
            "dependencies": chart['dependencies'],
            "chart_lock_state": chart['chart_lock_state'],
            "oci_requirement": chart['oci_requirement'],
            "oci_repository": chart['oci_repository'],
            "known_oci_digest": catalog_charts_map.get(sp, {}).get('known_oci_digest')
        })

    # Helper script locations
    resolve_script = script_dir / "resolve-image.sh"
    if not resolve_script.exists():
        resolve_script = repo_root / "scripts" / "supply-chain" / "resolve-image.sh"

    scan_script = script_dir / "scan-image.sh"
    if not scan_script.exists():
        scan_script = repo_root / "scripts" / "supply-chain" / "scan-image.sh"

    verify_script = script_dir / "verify-image.sh"
    if not verify_script.exists():
        verify_script = repo_root / "scripts" / "supply-chain" / "verify-image.sh"

    # 2. Audit Images & Compare Catalog
    for img in discovered_images:
        img_ref = img['image']
        source_paths = img['source_paths']
        ownership = img['ownership']
        mutable_tag = img['mutable_tag']

        prev_entry = catalog_images_map.get(img_ref, {})
        is_new = (img_ref not in catalog_images_map)

        if is_new:
            f = {
                "type": "NEW_IMAGE",
                "artifact": img_ref,
                "source_paths": source_paths,
                "evidence": {
                    "image": img_ref,
                    "ownership": ownership,
                    "mutable_tag": mutable_tag
                }
            }
            findings.append(f)

            f_uncat = {
                "type": "UNCATALOGUED_ARTIFACT",
                "artifact": img_ref,
                "source_paths": source_paths,
                "evidence": {
                    "image": img_ref,
                    "artifact_type": "IMAGE"
                }
            }
            findings.append(f_uncat)

        if mutable_tag:
            f = {
                "type": "MUTABLE_TAG",
                "artifact": img_ref,
                "source_paths": source_paths,
                "evidence": {
                    "image": img_ref,
                    "source_tag": img['source_tag']
                }
            }
            findings.append(f)

        top_digest = prev_entry.get('top_level_digest')
        amd64_digest = prev_entry.get('platforms', {}).get('linux/amd64', {}).get('digest')
        arm64_digest = prev_entry.get('platforms', {}).get('linux/arm64', {}).get('digest')
        amd64_avail = prev_entry.get('platforms', {}).get('linux/amd64', {}).get('available', False)
        arm64_avail = prev_entry.get('platforms', {}).get('linux/arm64', {}).get('available', False)
        amd64_sbom = prev_entry.get('platforms', {}).get('linux/amd64', {}).get('sbom_status', 'MISSING')
        arm64_sbom = prev_entry.get('platforms', {}).get('linux/arm64', {}).get('sbom_status', 'MISSING')
        amd64_vuln = prev_entry.get('platforms', {}).get('linux/amd64', {}).get('vulnerability_status', 'UNSCANNED')
        arm64_vuln = prev_entry.get('platforms', {}).get('linux/arm64', {}).get('vulnerability_status', 'UNSCANNED')
        prov_status = prev_entry.get('provenance_status', 'UNVERIFIED')

        # If --scan is enabled, run online resolution, scanning, and verification
        if args.scan:
            if resolve_script.exists():
                try:
                    proc_res = subprocess.run([str(resolve_script), img_ref], capture_output=True, text=True)
                    if proc_res.returncode == 0:
                        res_data = json.loads(proc_res.stdout)
                        curr_top_digest = res_data.get('top_level_digest')
                        curr_amd64 = res_data.get('platforms', {}).get('linux/amd64', {})
                        curr_arm64 = res_data.get('platforms', {}).get('linux/arm64', {})

                        # Check PLATFORM_DIGEST_DRIFT
                        if amd64_digest and curr_amd64.get('digest') and amd64_digest != curr_amd64.get('digest'):
                            f = {
                                "type": "PLATFORM_DIGEST_DRIFT",
                                "artifact": img_ref,
                                "source_paths": source_paths,
                                "evidence": {
                                    "platform": "linux/amd64",
                                    "previous_digest": amd64_digest,
                                    "current_digest": curr_amd64.get('digest')
                                }
                            }
                            findings.append(f)

                        if arm64_digest and curr_arm64.get('digest') and arm64_digest != curr_arm64.get('digest'):
                            f = {
                                "type": "PLATFORM_DIGEST_DRIFT",
                                "artifact": img_ref,
                                "source_paths": source_paths,
                                "evidence": {
                                    "platform": "linux/arm64",
                                    "previous_digest": arm64_digest,
                                    "current_digest": curr_arm64.get('digest')
                                }
                            }
                            findings.append(f)

                        top_digest = curr_top_digest
                        amd64_digest = curr_amd64.get('digest')
                        amd64_avail = curr_amd64.get('available', False)
                        arm64_digest = curr_arm64.get('digest')
                        arm64_avail = curr_arm64.get('available', False)

                except Exception as ex:
                    sys.stderr.write(f"Resolution failed for {img_ref}: {ex}\n")

            # Perform Syft/Grype scan for available platforms if new/changed/unscanned
            if scan_script.exists():
                for platform, p_avail, p_digest in [("linux/amd64", amd64_avail, amd64_digest), ("linux/arm64", arm64_avail, arm64_digest)]:
                    if p_avail:
                        arch_key = "amd64" if "amd64" in platform else "arm64"
                        try:
                            proc_scan = subprocess.run([str(scan_script), img_ref, platform, p_digest or ""], capture_output=True, text=True)
                            if proc_scan.returncode == 0:
                                scan_data = json.loads(proc_scan.stdout)
                                s_status = scan_data.get('sbom_status', 'MISSING')
                                v_status = scan_data.get('vulnerability_status', 'UNSCANNED')

                                if arch_key == "amd64":
                                    amd64_sbom = s_status
                                    amd64_vuln = v_status
                                else:
                                    arm64_sbom = s_status
                                    arm64_vuln = v_status

                                for sf in scan_data.get('findings', []):
                                    f_obj = {
                                        "type": sf.get('type'),
                                        "artifact": img_ref,
                                        "source_paths": source_paths,
                                        "evidence": {
                                            "platform": platform,
                                            "message": sf.get('message')
                                        }
                                    }
                                    findings.append(f_obj)
                        except Exception as ex:
                            sys.stderr.write(f"Scan failed for {img_ref} ({platform}): {ex}\n")

            # Perform Cosign verification
            if verify_script.exists():
                try:
                    proc_ver = subprocess.run([str(verify_script), img_ref, ownership], capture_output=True, text=True)
                    if proc_ver.returncode == 0:
                        ver_data = json.loads(proc_ver.stdout)
                        prov_status = ver_data.get('provenance_status', 'UNVERIFIED')
                        for vf in ver_data.get('findings', []):
                            f_obj = {
                                "type": vf.get('type'),
                                "artifact": img_ref,
                                "source_paths": source_paths,
                                "evidence": {
                                    "ownership": ownership,
                                    "message": vf.get('message')
                                }
                            }
                            findings.append(f_obj)
                except Exception as ex:
                    sys.stderr.write(f"Verify failed for {img_ref}: {ex}\n")

        # Platform missing findings
        if not amd64_avail:
            f = {
                "type": "PLATFORM_AMD64_MISSING",
                "artifact": img_ref,
                "source_paths": source_paths,
                "evidence": {
                    "image": img_ref,
                    "platform": "linux/amd64"
                }
            }
            findings.append(f)

        if not arm64_avail:
            f = {
                "type": "PLATFORM_ARM64_MISSING",
                "artifact": img_ref,
                "source_paths": source_paths,
                "evidence": {
                    "image": img_ref,
                    "platform": "linux/arm64"
                }
            }
            findings.append(f)

        if not top_digest:
            f = {
                "type": "IMAGE_DIGEST_MISSING",
                "artifact": img_ref,
                "source_paths": source_paths,
                "evidence": {
                    "image": img_ref
                }
            }
            findings.append(f)

        # SBOM & Vulnerability checks
        if amd64_avail and amd64_sbom == "MISSING":
            f = {
                "type": "SBOM_AMD64_MISSING",
                "artifact": img_ref,
                "source_paths": source_paths,
                "evidence": {"platform": "linux/amd64"}
            }
            findings.append(f)

        if arm64_avail and arm64_sbom == "MISSING":
            f = {
                "type": "SBOM_ARM64_MISSING",
                "artifact": img_ref,
                "source_paths": source_paths,
                "evidence": {"platform": "linux/arm64"}
            }
            findings.append(f)

        if amd64_vuln == "EXCEEDED":
            f = {
                "type": "VULNERABILITY_AMD64_THRESHOLD_EXCEEDED",
                "artifact": img_ref,
                "source_paths": source_paths,
                "evidence": {"platform": "linux/amd64"}
            }
            findings.append(f)

        if arm64_vuln == "EXCEEDED":
            f = {
                "type": "VULNERABILITY_ARM64_THRESHOLD_EXCEEDED",
                "artifact": img_ref,
                "source_paths": source_paths,
                "evidence": {"platform": "linux/arm64"}
            }
            findings.append(f)

        # Provenance check
        if ownership == "FIRST_PARTY_IMAGE":
            if prov_status != "VERIFIED":
                f = {
                    "type": "FIRST_PARTY_SIGNATURE_MISSING",
                    "artifact": img_ref,
                    "source_paths": source_paths,
                    "evidence": {"image": img_ref, "ownership": ownership}
                }
                findings.append(f)
        else:
            if prov_status != "VERIFIED":
                f = {
                    "type": "UPSTREAM_PROVENANCE_UNVERIFIED",
                    "artifact": img_ref,
                    "source_paths": source_paths,
                    "evidence": {"image": img_ref, "ownership": ownership}
                }
                findings.append(f)

        updated_catalog_images.append({
            "id": img_ref,
            "image": img_ref,
            "ownership": ownership,
            "source_paths": source_paths,
            "source_tag": img['source_tag'],
            "top_level_digest": top_digest,
            "platforms": {
                "linux/amd64": {
                    "digest": amd64_digest,
                    "available": amd64_avail,
                    "sbom_status": amd64_sbom,
                    "vulnerability_status": amd64_vuln
                },
                "linux/arm64": {
                    "digest": arm64_digest,
                    "available": arm64_avail,
                    "sbom_status": arm64_sbom,
                    "vulnerability_status": arm64_vuln
                }
            },
            "provenance_status": prov_status
        })

    # 3. Check for new Dockerfiles
    catalog_dockerfiles = catalog.get('dockerfiles', [])
    for df in dockerfile_list:
        if df not in catalog_dockerfiles:
            f = {
                "type": "NEW_DOCKERFILE",
                "artifact": df,
                "source_paths": [df],
                "evidence": {"source_path": df}
            }
            findings.append(f)

    # Remove duplicates from findings based on (type, artifact, source_path)
    unique_findings = []
    seen_findings = set()
    for fn in findings:
        key = (fn.get('type'), fn.get('artifact'), tuple(sorted(fn.get('source_paths', []))))
        if key not in seen_findings:
            seen_findings.add(key)
            unique_findings.append(fn)

    # Output / Update
    if args.update_catalog:
        catalog_data = {
            "version": "1.0",
            "updated_at": subprocess.check_output(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"]).decode().strip(),
            "dockerfiles": dockerfile_list,
            "images": updated_catalog_images,
            "helm_charts": updated_catalog_charts
        }
        save_yaml(catalog_path, catalog_data)

    res = {
        "finding_count": len(unique_findings),
        "findings": unique_findings
    }

    out_json = json.dumps(res, indent=2)
    if args.output:
        with open(args.output, 'w', encoding='utf-8') as f:
            f.write(out_json)
    else:
        print(out_json)

if __name__ == '__main__':
    main()
