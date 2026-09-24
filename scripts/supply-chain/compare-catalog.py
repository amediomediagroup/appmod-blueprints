#!/usr/bin/env parser
"""
compare-catalog.py

Compares current codebase artifacts (discovered images and Helm charts)
against the canonical catalog (.supply-chain/artifacts.yaml) and policy (.supply-chain/policy.yaml).

Uses shared policy.py module to enforce policy rules and fail closed on invalid configuration.
"""

import os
import sys
import json
import argparse
import subprocess
import importlib.util
from pathlib import Path
import yaml

def get_script_dir():
    if "SUPPLY_CHAIN_DIR" in os.environ and os.path.exists(os.path.join(os.environ["SUPPLY_CHAIN_DIR"], "policy.py")):
        return Path(os.environ["SUPPLY_CHAIN_DIR"]).resolve()

    for p in sys.path:
        if p and os.path.exists(os.path.join(p, "policy.py")):
            return Path(p).resolve()

    fixed = Path("/app/scripts/supply-chain").resolve()
    if (fixed / "policy.py").exists():
        return fixed

    return Path(__file__).resolve().parent

SCRIPT_DIR = get_script_dir()
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

spec_pol = importlib.util.spec_from_file_location("policy", SCRIPT_DIR / "policy.py")
policy_module = importlib.util.module_from_spec(spec_pol)
spec_pol.loader.exec_module(policy_module)

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
    catalog_path = repo_root / args.catalog
    policy_path = repo_root / args.policy if args.policy else None

    # Load validated policy - fails closed if missing/malformed
    try:
        policy = policy_module.load_policy(policy_path=policy_path, repo_root=repo_root)
    except Exception as ex:
        sys.stderr.write(f"Policy validation error: {ex}\n")
        sys.exit(1)

    target_platforms = policy["target_platforms"]
    require_chart_lock = policy["helm_policy"]["require_chart_lock_if_dependencies"]

    catalog = load_yaml(catalog_path)

    catalog_images_map = {img['image']: img for img in catalog.get('images', [])}
    catalog_charts_map = {c['source_path']: c for c in catalog.get('helm_charts', [])}

    disc_img_path = SCRIPT_DIR / "discover-images.py"
    spec_img = importlib.util.spec_from_file_location("discover_images", disc_img_path)
    discover_images = importlib.util.module_from_spec(spec_img)
    spec_img.loader.exec_module(discover_images)

    disc_helm_path = SCRIPT_DIR / "discover-helm.py"
    spec_helm = importlib.util.spec_from_file_location("discover_helm", disc_helm_path)
    discover_helm = importlib.util.module_from_spec(spec_helm)
    spec_helm.loader.exec_module(discover_helm)

    discovered_images, dockerfile_list, unresolved_dynamic_images, _ = discover_images.discover_all(repo_root, policy_path=policy_path)
    discovered_charts = discover_helm.discover_helm_charts(repo_root, policy_path=policy_path)

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

        if chart['chart_lock_state'] == "MISSING" and require_chart_lock:
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
    resolve_script = SCRIPT_DIR / "resolve-image.sh"
    scan_script = SCRIPT_DIR / "scan-image.sh"
    verify_script = SCRIPT_DIR / "verify-image.sh"

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

        # Build platform state dynamically based on policy target_platforms
        platforms_dict = {}
        for plat in target_platforms:
            prev_plat = prev_entry.get('platforms', {}).get(plat, {})
            platforms_dict[plat] = {
                "digest": prev_plat.get('digest'),
                "available": prev_plat.get('available', False),
                "sbom_status": prev_plat.get('sbom_status', 'MISSING'),
                "vulnerability_status": prev_plat.get('vulnerability_status', 'UNSCANNED')
            }

        prov_status = prev_entry.get('provenance_status', 'UNVERIFIED')

        # If --scan is enabled, run online resolution, scanning, and verification
        if args.scan:
            if resolve_script.exists():
                try:
                    proc_res = subprocess.run([str(resolve_script), img_ref, str(policy_path or "")], capture_output=True, text=True)
                    if proc_res.returncode == 0:
                        res_data = json.loads(proc_res.stdout)
                        curr_top_digest = res_data.get('top_level_digest')
                        curr_platforms = res_data.get('platforms', {})

                        for plat in target_platforms:
                            curr_p = curr_platforms.get(plat, {})
                            prev_d = platforms_dict[plat]["digest"]
                            curr_d = curr_p.get('digest')

                            if prev_d and curr_d and prev_d != curr_d:
                                f = {
                                    "type": "PLATFORM_DIGEST_DRIFT",
                                    "artifact": img_ref,
                                    "source_paths": source_paths,
                                    "evidence": {
                                        "platform": plat,
                                        "previous_digest": prev_d,
                                        "current_digest": curr_d
                                    }
                                }
                                findings.append(f)

                            platforms_dict[plat]["digest"] = curr_d
                            platforms_dict[plat]["available"] = curr_p.get('available', False)

                        top_digest = curr_top_digest

                except Exception as ex:
                    sys.stderr.write(f"Resolution failed for {img_ref}: {ex}\n")

            # Perform Syft/Grype scan for available platforms
            if scan_script.exists():
                for plat in target_platforms:
                    if platforms_dict[plat]["available"]:
                        p_digest = platforms_dict[plat]["digest"] or ""
                        try:
                            proc_scan = subprocess.run([str(scan_script), img_ref, plat, p_digest, str(policy_path or "")], capture_output=True, text=True)
                            if proc_scan.returncode == 0:
                                scan_data = json.loads(proc_scan.stdout)
                                platforms_dict[plat]["sbom_status"] = scan_data.get('sbom_status', 'MISSING')
                                platforms_dict[plat]["vulnerability_status"] = scan_data.get('vulnerability_status', 'UNSCANNED')

                                for sf in scan_data.get('findings', []):
                                    f_obj = {
                                        "type": sf.get('type'),
                                        "artifact": img_ref,
                                        "source_paths": source_paths,
                                        "evidence": {
                                            "platform": plat,
                                            "message": sf.get('message')
                                        }
                                    }
                                    findings.append(f_obj)
                        except Exception as ex:
                            sys.stderr.write(f"Scan failed for {img_ref} ({plat}): {ex}\n")

            # Perform Cosign verification
            if verify_script.exists():
                try:
                    proc_ver = subprocess.run([str(verify_script), img_ref, ownership, str(policy_path or "")], capture_output=True, text=True)
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

        # Check platform availability for target_platforms dynamically
        for plat in target_platforms:
            arch_label = "AMD64" if "amd64" in plat else ("ARM64" if "arm64" in plat else plat.replace("/", "_").upper())
            if not platforms_dict[plat]["available"]:
                f = {
                    "type": f"PLATFORM_{arch_label}_MISSING",
                    "artifact": img_ref,
                    "source_paths": source_paths,
                    "evidence": {
                        "image": img_ref,
                        "platform": plat
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

        # Check SBOM & Vulnerability status per target platform
        for plat in target_platforms:
            arch_label = "AMD64" if "amd64" in plat else ("ARM64" if "arm64" in plat else plat.replace("/", "_").upper())
            p_state = platforms_dict[plat]

            if p_state["available"] and p_state["sbom_status"] == "MISSING":
                f = {
                    "type": f"SBOM_{arch_label}_MISSING",
                    "artifact": img_ref,
                    "source_paths": source_paths,
                    "evidence": {"platform": plat}
                }
                findings.append(f)

            if p_state["vulnerability_status"] == "EXCEEDED":
                f = {
                    "type": f"VULNERABILITY_{arch_label}_THRESHOLD_EXCEEDED",
                    "artifact": img_ref,
                    "source_paths": source_paths,
                    "evidence": {"platform": plat}
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
            "platforms": platforms_dict,
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

    # Deduplicate findings deterministically
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
