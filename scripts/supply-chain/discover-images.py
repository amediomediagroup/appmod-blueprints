#!/usr/bin/env python3
"""
discover-images.py

Discovers image references across the repository including:
- Dockerfile / Containerfile FROM / COPY --from
- Kubernetes manifests (containers, initContainers, ephemeralContainers, Jobs, CronJobs, sidecars, Helm hooks)
- Helm values and templates
- Kustomize patches
- ArgoCD Applications / ApplicationSets
- Kargo resources
- CI workflows and scripts
- Test manifests

Classifies images into FIRST_PARTY_IMAGE, THIRD_PARTY_IMAGE, or UNKNOWN.
"""

import os
import re
import sys
import json
import argparse
from pathlib import Path
import yaml

EXCLUDE_DIRS = {
    '.git', '.kiro', 'node_modules', '.venv', '__pycache__', 'dist', 'build', '.supply-chain'
}

FIRST_PARTY_DOCKERFILE_DIRS = [
    'applications', 'backstage', 'cluster-providers', 'platform'
]

FIRST_PARTY_PATTERNS = [
    r'^public\.ecr\.aws/aegis/',
    r'^aegis/',
    r'^localhost/',
    r'^internal/',
]

MUTABLE_TAG_PATTERNS = [
    r':latest$',
    r':main$',
    r':master$',
    r':dev$',
    r':canary$',
    r':nightly$',
    r':stable$',
    r':head$',
]

INVALID_IMAGE_VALUES = {
    'string', 'object', 'array', 'boolean', 'integer', 'number', 'null',
    'scratch', 'source', 'build', 'default', 'none', 'true', 'false'
}

def is_valid_image_ref(img: str) -> bool:
    if not img or not isinstance(img, str):
        return False
    img_stripped = img.strip()
    img_lower = img_stripped.lower()

    if img_lower in INVALID_IMAGE_VALUES:
        return False
    if img_stripped.startswith('http://') or img_stripped.startswith('https://'):
        return False
    if img_stripped.startswith('<') or img_stripped.startswith('{{') or img_stripped.startswith('${'):
        return False
    if ' ' in img_stripped or '\t' in img_stripped or '\n' in img_stripped:
        return False
    if not re.search(r'[a-zA-Z0-9]', img_stripped):
        return False
    return True

def classify_image(image_ref: str, source_paths: list, dockerfiles_found: set) -> str:
    for pattern in FIRST_PARTY_PATTERNS:
        if re.search(pattern, image_ref):
            return "FIRST_PARTY_IMAGE"

    image_lower = image_ref.lower()
    for df in dockerfiles_found:
        df_dir = os.path.dirname(df).lower()
        if df_dir and (df_dir in image_lower or os.path.basename(df_dir) in image_lower):
            return "FIRST_PARTY_IMAGE"

    if "{{" in image_ref or "${" in image_ref or image_ref.startswith(":") or not image_ref:
        return "UNKNOWN"

    return "THIRD_PARTY_IMAGE"

def is_mutable_tag(image_ref: str) -> bool:
    if "@sha256:" in image_ref:
        return False
    if ":" not in image_ref:
        return True
    for pat in MUTABLE_TAG_PATTERNS:
        if re.search(pat, image_ref, re.IGNORECASE):
            return True
    return False

def parse_dockerfile(filepath: Path) -> list:
    images = []
    stage_names = set()
    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            lines = f.readlines()

        for line_no, raw_line in enumerate(lines, 1):
            line = raw_line.strip()
            if line.upper().startswith('FROM '):
                parts = line.split()
                if len(parts) >= 2:
                    img = parts[1]
                    if len(parts) >= 4 and parts[2].upper() == 'AS':
                        stage_names.add(parts[3].lower())
                    if is_valid_image_ref(img) and img.lower() not in stage_names:
                        images.append({
                            'image': img,
                            'line': line_no,
                            'context': 'FROM'
                        })
            elif '--from=' in line:
                match = re.search(r'--from=([^\s]+)', line)
                if match:
                    img = match.group(1)
                    if is_valid_image_ref(img) and not img.isdigit() and img.lower() not in stage_names:
                        images.append({
                            'image': img,
                            'line': line_no,
                            'context': 'COPY --from'
                        })
    except Exception as e:
        sys.stderr.write(f"Error reading {filepath}: {e}\n")
    return images

def extract_images_from_yaml_obj(obj, context="yaml", images_acc=None):
    if images_acc is None:
        images_acc = []

    if isinstance(obj, dict):
        if 'image' in obj and isinstance(obj['image'], str):
            img = obj['image'].strip()
            if is_valid_image_ref(img):
                images_acc.append({'image': img, 'context': context})

        if 'repository' in obj and isinstance(obj['repository'], str):
            repo = obj['repository'].strip()
            tag = obj.get('tag', '')
            if is_valid_image_ref(repo):
                if isinstance(tag, (str, int, float)):
                    tag_str = str(tag).strip()
                    full_img = f"{repo}:{tag_str}" if tag_str and not tag_str.startswith('http') else repo
                else:
                    full_img = repo
                if is_valid_image_ref(full_img):
                    images_acc.append({'image': full_img, 'context': f"{context}.repository+tag"})

        for k, v in obj.items():
            extract_images_from_yaml_obj(v, f"{context}.{k}", images_acc)
    elif isinstance(obj, list):
        for idx, item in enumerate(obj):
            extract_images_from_yaml_obj(item, f"{context}[{idx}]", images_acc)

    return images_acc

def parse_yaml_file(filepath: Path) -> list:
    images = []
    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
            docs = yaml.safe_load_all(content)
            for doc in docs:
                if doc:
                    extract_images_from_yaml_obj(doc, "yaml", images)
    except Exception:
        try:
            with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
                for line_no, line in enumerate(f, 1):
                    match = re.search(r'image:\s*["\']?([^\s"\'#]+)', line)
                    if match:
                        img = match.group(1).strip()
                        if is_valid_image_ref(img):
                            images.append({'image': img, 'context': f'line:{line_no}'})
        except Exception:
            pass
    return images

def parse_code_or_script_file(filepath: Path) -> list:
    images = []
    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            for line_no, line in enumerate(f, 1):
                matches = re.findall(r'(?:public\.ecr\.aws|quay\.io|gcr\.io|ghcr\.io|docker\.io|registry\.k8s\.io|ecr\.[a-z0-9-]+\.amazonaws\.com)/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+(?::[a-zA-Z0-9_.-]+)?', line)
                for m in matches:
                    if is_valid_image_ref(m):
                        images.append({'image': m, 'context': f'script_line:{line_no}'})
    except Exception:
        pass
    return images

def discover_all(repo_root: Path):
    dockerfiles_found = set()
    discovered_images = {}
    dockerfile_list = []

    for root, dirs, files in os.walk(repo_root):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]
        for file in files:
            rel_path = os.path.relpath(os.path.join(root, file), repo_root)
            if file.startswith('Dockerfile') or file.startswith('Containerfile'):
                dockerfiles_found.add(rel_path)
                dockerfile_list.append(rel_path)

    for root, dirs, files in os.walk(repo_root):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]
        for file in files:
            full_path = Path(root) / file
            rel_path = os.path.relpath(full_path, repo_root)

            extracted = []
            if file.startswith('Dockerfile') or file.startswith('Containerfile'):
                extracted = parse_dockerfile(full_path)
            elif file.endswith('.yaml') or file.endswith('.yml'):
                extracted = parse_yaml_file(full_path)
            elif file.endswith('.sh') or file.endswith('.py') or rel_path.startswith('.github/'):
                extracted = parse_code_or_script_file(full_path)

            for item in extracted:
                img_ref = item['image'].strip()
                if not is_valid_image_ref(img_ref):
                    continue

                if img_ref not in discovered_images:
                    classification = classify_image(img_ref, [rel_path], dockerfiles_found)
                    mutable = is_mutable_tag(img_ref)
                    tag = ""
                    digest = ""
                    if "@sha256:" in img_ref:
                        parts = img_ref.split("@sha256:")
                        digest = "sha256:" + parts[1]
                        tag_part = parts[0]
                        tag = tag_part.split(":")[-1] if ":" in tag_part else ""
                    elif ":" in img_ref:
                        tag = img_ref.split(":")[-1]

                    discovered_images[img_ref] = {
                        'image': img_ref,
                        'source_paths': [rel_path],
                        'ownership': classification,
                        'source_tag': tag,
                        'pinned_digest': digest,
                        'mutable_tag': mutable,
                        'contexts': [f"{rel_path} ({item['context']})"]
                    }
                else:
                    if rel_path not in discovered_images[img_ref]['source_paths']:
                        discovered_images[img_ref]['source_paths'].append(rel_path)
                    ctx = f"{rel_path} ({item['context']})"
                    if ctx not in discovered_images[img_ref]['contexts']:
                        discovered_images[img_ref]['contexts'].append(ctx)

    return list(discovered_images.values()), sorted(dockerfile_list)

def main():
    parser = argparse.ArgumentParser(description="Discover image references across repository.")
    parser.add_argument("--repo-root", default=".", help="Repository root path")
    parser.add_argument("--output", default=None, help="Output JSON file path")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    images, dockerfiles = discover_all(repo_root)

    result = {
        'dockerfiles': dockerfiles,
        'image_count': len(images),
        'images': images
    }

    out_json = json.dumps(result, indent=2)
    if args.output:
        with open(args.output, 'w', encoding='utf-8') as f:
            f.write(out_json)
    else:
        print(out_json)

if __name__ == '__main__':
    main()
