#!/usr/bin/env bash
set -euo pipefail

# audit-helm.sh
# Usage: ./audit-helm.sh [--repo-root PATH] [--policy PATH] [--output FILE]

python3 - "$@" << 'EOF'
import sys
import os
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

script_dir = get_script_dir()
if str(script_dir) not in sys.path:
    sys.path.insert(0, str(script_dir))

import policy as policy_module

def main():
    parser = argparse.ArgumentParser(description="Audit Helm charts in repository")
    parser.add_argument("--repo-root", default=".", help="Repository root path")
    parser.add_argument("--policy", default=None, help="Policy YAML path")
    parser.add_argument("--output", default=None, help="Output JSON file")
    args = parser.parse_args(sys.argv[1:])

    repo_root = Path(args.repo_root).resolve()
    policy_path = Path(args.policy).resolve() if args.policy else None

    policy = policy_module.load_policy(policy_path=policy_path, repo_root=repo_root)

    disc_helm_path = script_dir / "discover-helm.py"
    import importlib.util
    spec = importlib.util.spec_from_file_location("discover_helm", disc_helm_path)
    discover_helm = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(discover_helm)

    charts = discover_helm.discover_helm_charts(repo_root, policy_path=policy_path)

    findings = []
    audited_charts = []
    require_lock = policy["helm_policy"]["require_chart_lock_if_dependencies"]

    for chart in charts:
        chart_findings = []
        source_path = chart['source_path']
        chart_dir = chart['chart_dir']
        chart_name = chart['chart_name']
        classification = chart['classification']
        dependencies = chart.get('dependencies', [])
        has_lock = chart.get('has_lock', False)

        # Check dependency repositories for classic HTTP/HTTPS repos (OCI-only requirement)
        for dep in dependencies:
            repo = dep.get("repository", "")
            if repo.startswith("http://") or repo.startswith("https://"):
                f = {
                    "type": "HELM_HTTP_REPO_DISALLOWED",
                    "artifact": chart_name,
                    "source_paths": [source_path],
                    "evidence": {
                        "source_path": source_path,
                        "dependency": dep.get("name"),
                        "repository": repo,
                        "reason": f"Chart dependency '{dep.get('name')}' uses classic HTTP/HTTPS repository '{repo}' instead of Aegis OCI mirror"
                    }
                }
                chart_findings.append(f)
                findings.append(f)

        # 1. Dependency checks: missing Chart.lock or range without lock (only if require_chart_lock_if_dependencies is true)
        if dependencies and require_lock:
            if not has_lock:
                f = {
                    "type": "HELM_LOCK_DRIFT",
                    "artifact": chart_name,
                    "source_paths": [source_path],
                    "evidence": {
                        "source_path": source_path,
                        "reason": "Dependencies declared in Chart.yaml but Chart.lock is missing"
                    }
                }
                chart_findings.append(f)
                findings.append(f)

            for dep in dependencies:
                ver = str(dep.get("version", ""))
                if any(c in ver for c in ["^", "~", ">", "<", "*"]) and not has_lock:
                    f = {
                        "type": "HELM_LOCK_DRIFT",
                        "artifact": chart_name,
                        "source_paths": [source_path],
                        "evidence": {
                            "source_path": source_path,
                            "dependency": dep.get("name"),
                            "version_range": ver,
                            "reason": f"Chart dependency '{dep.get('name')}' uses floating version range '{ver}' without Chart.lock"
                        }
                    }
                    chart_findings.append(f)
                    findings.append(f)

        # 2. OCI candidate release check
        if classification == "RELEASE_ARTIFACT_OCI_CANDIDATE":
            known_digest = chart.get('known_oci_digest')
            if not known_digest:
                f = {
                    "type": "HELM_OCI_MISSING",
                    "artifact": chart_name,
                    "source_paths": [source_path],
                    "evidence": {
                        "source_path": source_path,
                        "classification": classification,
                        "reason": "Missing OCI release digest for OCI candidate chart"
                    }
                }
                chart_findings.append(f)
                findings.append(f)

        audited_charts.append({
            "chart": chart,
            "findings": chart_findings
        })

    res = {
        "audited_chart_count": len(audited_charts),
        "finding_count": len(findings),
        "findings": findings,
        "charts": audited_charts
    }

    out_json = json.dumps(res, indent=2)
    if args.output:
        with open(args.output, 'w', encoding='utf-8') as f:
            f.write(out_json)
    else:
        print(out_json)

if __name__ == '__main__':
    main()

EOF
