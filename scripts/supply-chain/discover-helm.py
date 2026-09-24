#!/usr/bin/env python3
"""
discover-helm.py

Discovers all Helm charts and references across the repository:
- Chart.yaml files
- Chart.lock files
- Dependencies
- ArgoCD Helm sources
- OCI references
- Versioning and classification using policy.py

Classifies charts into categories defined in .supply-chain/policy.yaml.
"""

import os
import sys
import json
import argparse
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

import policy as policy_module

EXCLUDE_DIRS = {
    '.git', '.kiro', 'node_modules', '.venv', '__pycache__', 'dist', 'build', '.supply-chain'
}

def discover_helm_charts(repo_root: Path, policy_path: Path = None):
    policy = policy_module.load_policy(policy_path=policy_path, repo_root=repo_root)
    charts = []

    for root, dirs, files in os.walk(repo_root):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]

        if 'Chart.yaml' in files or 'Chart.yml' in files:
            chart_file_name = 'Chart.yaml' if 'Chart.yaml' in files else 'Chart.yml'
            chart_file_path = Path(root) / chart_file_name
            rel_chart_dir = os.path.relpath(root, repo_root)
            rel_chart_file = os.path.relpath(chart_file_path, repo_root)

            lock_file_path = Path(root) / 'Chart.lock'
            has_lock = lock_file_path.exists()
            rel_lock_file = os.path.relpath(lock_file_path, repo_root) if has_lock else None

            chart_data = {}
            try:
                with open(chart_file_path, 'r', encoding='utf-8') as f:
                    chart_data = yaml.safe_load(f) or {}
            except Exception as e:
                sys.stderr.write(f"Error reading {chart_file_path}: {e}\n")

            chart_name = chart_data.get('name', os.path.basename(root))
            chart_version = chart_data.get('version', '')
            dependencies = chart_data.get('dependencies', [])

            if dependencies:
                if has_lock:
                    chart_lock_state = "PRESENT"
                else:
                    chart_lock_state = "MISSING"
            else:
                chart_lock_state = "NOT_REQUIRED"

            classification = policy_module.classify_helm_chart(rel_chart_dir, policy)

            charts.append({
                'source_path': rel_chart_file,
                'chart_dir': rel_chart_dir,
                'chart_name': chart_name,
                'version': str(chart_version),
                'classification': classification,
                'dependencies': dependencies,
                'has_lock': has_lock,
                'chart_lock_file': rel_lock_file,
                'chart_lock_state': chart_lock_state,
                'oci_requirement': (classification == "RELEASE_ARTIFACT_OCI_CANDIDATE"),
                'oci_repository': f"oci://public.ecr.aws/aegis/{chart_name}" if classification == "RELEASE_ARTIFACT_OCI_CANDIDATE" else None,
                'known_oci_digest': None
            })

    return sorted(charts, key=lambda x: x['source_path'])

def main():
    parser = argparse.ArgumentParser(description="Discover Helm charts and dependencies.")
    parser.add_argument("--repo-root", default=".", help="Repository root path")
    parser.add_argument("--policy", default=None, help="Policy YAML path")
    parser.add_argument("--output", default=None, help="Output JSON file path")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    policy_path = Path(args.policy).resolve() if args.policy else None

    charts = discover_helm_charts(repo_root, policy_path=policy_path)

    result = {
        'chart_count': len(charts),
        'helm_charts': charts
    }

    out_json = json.dumps(result, indent=2)
    if args.output:
        with open(args.output, 'w', encoding='utf-8') as f:
            f.write(out_json)
    else:
        print(out_json)

if __name__ == '__main__':
    main()
