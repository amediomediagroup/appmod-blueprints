#!/usr/bin/env python3
"""
build-import-matrix.py

Reads .supply-chain/upstream-helm-catalog.yaml and emits a GitHub Actions
matrix JSON — one entry per chart — so every catalog entry is imported,
OCI-mirrored, and Cosign-signed.

Output (written to stdout for use with `>> $GITHUB_OUTPUT`):
    matrix=[{"vendor":"...","chart_name":"...","version":"...","upstream_repo_url":"..."},...]
    has_charts=true|false

Usage:
    python3 scripts/supply-chain/build-import-matrix.py [--repo-root <path>]
"""

import argparse
import json
import sys
from pathlib import Path

import yaml


def load_catalog(catalog_path: Path) -> list[dict]:
    with open(catalog_path, encoding="utf-8") as f:
        raw = yaml.safe_load(f) or {}
    charts = raw.get("charts", [])
    for entry in charts:
        for required in ("vendor", "chart_name", "version", "upstream_repo"):
            if not entry.get(required):
                print(
                    f"[ERROR] catalog entry missing '{required}': {entry}",
                    file=sys.stderr,
                )
                sys.exit(1)
    return charts


def build_matrix(charts: list[dict]) -> list[dict]:
    return [
        {
            "vendor": c["vendor"],
            "chart_name": c["chart_name"],
            "version": str(c["version"]),
            "upstream_repo_url": c["upstream_repo"],
        }
        for c in charts
    ]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", default=".", help="Repository root")
    args = parser.parse_args()

    catalog_path = Path(args.repo_root).resolve() / ".supply-chain" / "upstream-helm-catalog.yaml"
    if not catalog_path.exists():
        print(f"[ERROR] catalog not found: {catalog_path}", file=sys.stderr)
        sys.exit(1)

    charts = load_catalog(catalog_path)
    matrix = build_matrix(charts)

    print(f"matrix={json.dumps(matrix)}")
    print(f"has_charts={'true' if matrix else 'false'}")


if __name__ == "__main__":
    main()
