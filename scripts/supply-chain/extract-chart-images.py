#!/usr/bin/env python3
"""
extract-chart-images.py

Extracts all container image references from a Helm chart .tgz file
by parsing values.yaml recursively for standard image patterns.

Patterns detected:
  1. {image: {repository: "...", tag: "...", registry: "..."}}
  2. {image: "registry/repo:tag"}
  3. Nested keys ending in Image/image with a string value
  4. Direct repository+tag sibling pairs at any depth

Output: one fully-qualified image reference per line (deduped, sorted).

Usage:
    python3 extract-chart-images.py <chart.tgz|chart_dir> [--json]
"""

import argparse
import json
import re
import sys
import tarfile
import tempfile
from pathlib import Path

import yaml


# ── Helpers ────────────────────────────────────────────────────────────────────

# Matches registry-like prefixes (optional), repo path, and tag/digest
_IMG_RE = re.compile(
    r"^(?:(?P<reg>[a-zA-Z0-9._\-]+\.[a-zA-Z]{2,}(?::\d+)?)/)?(?P<repo>[a-z0-9._/\-]+)(?::(?P<tag>[a-zA-Z0-9._\-]+))?(?:@(?P<digest>sha256:[0-9a-f]+))?$"
)
_KNOWN_REGISTRIES = {
    "docker.io", "ghcr.io", "quay.io", "gcr.io", "registry.k8s.io",
    "public.ecr.aws", "k8s.gcr.io", "mcr.microsoft.com", "nvcr.io",
}


def _is_image_like(s: str) -> bool:
    """Heuristic: is this string a container image reference?"""
    if not s or len(s) < 3 or " " in s or "\n" in s:
        return False
    m = _IMG_RE.match(s)
    if not m:
        return False
    repo = m.group("repo") or ""
    # Must have at least one slash OR look like a known registry path
    if "/" not in repo and not m.group("reg"):
        return False
    return True


def _normalize(ref: str) -> str:
    """Add docker.io/ prefix for bare image names."""
    if ref.startswith("docker.io/"):
        return ref
    m = _IMG_RE.match(ref)
    if not m:
        return ref
    reg = m.group("reg")
    if not reg:
        return f"docker.io/{ref}"
    return ref


def _build_ref(registry: str, repository: str, tag: str, digest: str) -> str:
    parts = []
    if registry:
        parts.append(registry.rstrip("/"))
    parts.append(repository.strip("/"))
    base = "/".join(parts)
    if digest:
        return f"{base}@{digest}"
    return f"{base}:{tag}" if tag else base


# ── Recursive extractor ────────────────────────────────────────────────────────

def _extract(node, images: set, depth: int = 0):
    """Walk a parsed YAML node and collect image references."""
    if depth > 20:
        return

    if isinstance(node, str):
        if _is_image_like(node):
            images.add(_normalize(node))
        return

    if isinstance(node, dict):
        # Pattern 1: {repository: ..., tag: ..., registry: ...}
        repo = node.get("repository", "")
        if isinstance(repo, str) and repo:
            tag      = str(node.get("tag", "latest") or "latest")
            digest   = str(node.get("digest", "") or "")
            registry = str(node.get("registry", "") or "")
            ref = _build_ref(registry, repo, tag, digest)
            if _is_image_like(ref) or "/" in repo:
                images.add(_normalize(ref))
            # Don't recurse into these — we've consumed them
            for k, v in node.items():
                if k not in ("repository", "tag", "digest", "registry"):
                    _extract(v, images, depth + 1)
            return

        # Pattern 2: {image: "full-ref"} or {image: {...}}
        img_val = node.get("image") or node.get("Image")
        if img_val is not None:
            _extract(img_val, images, depth + 1)

        # Recurse into all values
        for k, v in node.items():
            _extract(v, images, depth + 1)
        return

    if isinstance(node, list):
        for item in node:
            _extract(item, images, depth + 1)


# ── Chart loader ───────────────────────────────────────────────────────────────

def _load_values(path: Path) -> dict:
    """Load values.yaml from a chart directory or .tgz."""
    if path.is_dir():
        vf = path / "values.yaml"
        if not vf.exists():
            return {}
        with open(vf) as f:
            return yaml.safe_load(f) or {}

    if path.suffix in (".tgz", ".gz"):
        with tarfile.open(path) as tf:
            for member in tf.getmembers():
                # values.yaml is at <chart-name>/values.yaml
                parts = Path(member.name).parts
                if len(parts) == 2 and parts[1] == "values.yaml":
                    fobj = tf.extractfile(member)
                    if fobj:
                        return yaml.safe_load(fobj.read()) or {}
        return {}

    raise ValueError(f"Unsupported chart path: {path}")


def extract_images(chart_path: Path) -> list[str]:
    values = _load_values(chart_path)
    images: set[str] = set()
    _extract(values, images)
    # Filter obvious non-images (version strings, empty tags, etc.)
    clean = set()
    for img in images:
        if not img or img.startswith("#"):
            continue
        # Must have at least a slash to be a real image repo path
        base = img.split("@")[0].split(":")[0]
        if "/" not in base:
            continue
        clean.add(img)
    return sorted(clean)


# ── CLI ────────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("chart", help="Path to chart .tgz or chart directory")
    ap.add_argument("--json", action="store_true", help="Output as JSON array")
    args = ap.parse_args()

    chart_path = Path(args.chart).resolve()
    if not chart_path.exists():
        print(f"[ERROR] chart not found: {chart_path}", file=sys.stderr)
        sys.exit(1)

    images = extract_images(chart_path)

    if args.json:
        print(json.dumps(images))
    else:
        for img in images:
            print(img)


if __name__ == "__main__":
    main()
