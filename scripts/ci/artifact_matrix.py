#!/usr/bin/env python3
"""Matrix builder for image-mirror.yml and helm-mirror.yml CI prepare steps.

Reads .github/images-to-mirror.yaml and writes GITHUB_OUTPUT lines:
  matrix=<JSON>
  has_images=true|false   (images sub-command)
  has_charts=true|false   (charts sub-command)

Validates acr_path fields to prevent OCI push path traversal.

Usage:
  python3 scripts/ci/artifact_matrix.py images [--input FILE] [--filter STR]
  python3 scripts/ci/artifact_matrix.py charts [--input FILE] [--filter STR]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

DEFAULT_INPUT = ".github/images-to-mirror.yaml"


def _load_yaml(path: str) -> dict[str, Any]:
    try:
        import yaml
    except ImportError:
        import subprocess
        subprocess.run(
            [sys.executable, "-m", "pip", "install", "pyyaml", "-q"], check=True
        )
        import yaml  # noqa: F811
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def validate_acr_path(path: str) -> str:
    """Reject acr_path values that would produce an OCI push path traversal.

    Raises ValueError if the path contains '..' or starts with '/'.
    """
    if ".." in path:
        raise ValueError(
            f"acr_path contains forbidden traversal sequence '..': {path!r}"
        )
    if path.startswith("/"):
        raise ValueError(f"acr_path must be relative (no leading '/'): {path!r}")
    return path


def build_image_matrix(
    data: dict[str, Any],
    filter_str: str,
) -> tuple[dict[str, Any], bool]:
    """Return (matrix_dict, has_images) for the image-mirror matrix.

    Each include entry carries only ``source`` and ``target`` keys so that
    fromJson() in GitHub Actions always sees a well-formed matrix.
    """
    images: list[dict[str, Any]] = data.get("images") or []
    if filter_str:
        images = [
            i
            for i in images
            if filter_str in i.get("source", "") or filter_str in i.get("target", "")
        ]
    if not images:
        return {"include": []}, False
    matrix = {
        "include": [{"source": i["source"], "target": i["target"]} for i in images]
    }
    return matrix, True


def build_chart_matrix(
    data: dict[str, Any],
    filter_str: str,
) -> tuple[dict[str, Any], bool]:
    """Return (matrix_dict, has_charts) for the helm-mirror matrix.

    Validates every acr_path in the result set to prevent OCI path traversal
    before the matrix reaches the GitHub Actions runner.
    """
    charts: list[dict[str, Any]] = data.get("helm_charts") or []
    if filter_str:
        charts = [c for c in charts if filter_str in c.get("name", "")]
    if not charts:
        return {"include": []}, False
    for chart in charts:
        validate_acr_path(chart.get("acr_path", ""))
    return {"include": charts}, True


def write_github_outputs(outputs: dict[str, str]) -> None:
    """Write key=value pairs to $GITHUB_OUTPUT (or stdout when not in CI)."""
    output_file = os.environ.get("GITHUB_OUTPUT")
    if output_file:
        with open(output_file, "a", encoding="utf-8") as f:
            for key, value in outputs.items():
                f.write(f"{key}={value}\n")
    else:
        for key, value in outputs.items():
            print(f"{key}={value}")


def _cmd_images(args: argparse.Namespace) -> int:
    data = _load_yaml(args.input)
    matrix, has = build_image_matrix(data, args.filter)
    write_github_outputs(
        {"matrix": json.dumps(matrix), "has_images": "true" if has else "false"}
    )
    if not has:
        msg = (
            f"No images matched filter {args.filter!r}"
            if args.filter
            else "No images in manifest"
        )
        print(msg, file=sys.stderr)
    else:
        print(f"Images to mirror: {len(matrix['include'])}", file=sys.stderr)
    return 0


def _cmd_charts(args: argparse.Namespace) -> int:
    data = _load_yaml(args.input)
    try:
        matrix, has = build_chart_matrix(data, args.filter)
    except ValueError as exc:
        print(f"::error::Invalid chart manifest: {exc}", file=sys.stderr)
        return 1
    write_github_outputs(
        {"matrix": json.dumps(matrix), "has_charts": "true" if has else "false"}
    )
    if not has:
        msg = (
            f"No charts matched filter {args.filter!r}"
            if args.filter
            else "No charts in manifest"
        )
        print(msg, file=sys.stderr)
    else:
        print(
            f"Charts to mirror: {[c['name'] for c in matrix['include']]}",
            file=sys.stderr,
        )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("images", "charts"):
        p = sub.add_parser(name)
        p.add_argument(
            "--input", default=DEFAULT_INPUT, help="Path to images-to-mirror.yaml"
        )
        p.add_argument("--filter", default="", help="Substring filter")
    args = parser.parse_args(argv)
    return _cmd_images(args) if args.command == "images" else _cmd_charts(args)


if __name__ == "__main__":
    sys.exit(main())
