#!/usr/bin/env python3
"""
discover-images.py

Discovers image references across the repository including:
- Dockerfile / Containerfile FROM / COPY --from (with ARG resolution)
- Kubernetes manifests (containers, initContainers, ephemeralContainers, Jobs, CronJobs, sidecars, Helm hooks)
- Helm values and templates
- Kustomize patches
- ArgoCD Applications / ApplicationSets
- Kargo resources
- CI workflows and scripts
- Test manifests

Classifies images into FIRST_PARTY_IMAGE, THIRD_PARTY_IMAGE, or UNKNOWN.
Emits UNRESOLVED_DYNAMIC_IMAGE for unresolvable variable/templated references.
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
    'scratch', 'source', 'build', 'default', 'none', 'true', 'false',
    'http', 'https', 'git', 'ssh', 'file', 'echo', 'run', 'set', 'export',
    'bash', 'sh', 'python', 'python3', 'curl', 'wget', 'cat', 'grep', 'sed', 'awk',
    'bin/bash', 'usr/bin/python', 'usr/bin/env'
}

NON_IMAGE_EXTENSIONS = (
    '.sh', '.py', '.yaml', '.yml', '.json', '.txt', '.md', '.tar.gz',
    '.tgz', '.tar', '.zip', '.gz', '.deb', '.rpm', '.js', '.ts', '.html'
)

def is_unresolved_dynamic_ref(img: str) -> bool:
    if not img or not isinstance(img, str):
        return False
    img_stripped = img.strip()
    if '${' in img_stripped or '{{' in img_stripped or '<' in img_stripped:
        return True
    if re.search(r'\$[a-zA-Z_][a-zA-Z0-9_]*', img_stripped):
        return True
    return False

def is_valid_image_ref(img: str) -> bool:
    if not img or not isinstance(img, str):
        return False
    img_stripped = img.strip()
    img_lower = img_stripped.lower()

    if is_unresolved_dynamic_ref(img_stripped):
        return False

    if img_lower in INVALID_IMAGE_VALUES:
        return False
    if img_stripped.startswith('http://') or img_stripped.startswith('https://') or img_stripped.startswith('git@') or img_stripped.startswith('ssh://'):
        return False
    if img_stripped.startswith('/') or img_stripped.startswith('./') or img_stripped.startswith('../'):
        return False

    # Filter out archive/script/doc extensions
    for ext in NON_IMAGE_EXTENSIONS:
        if img_lower.endswith(ext):
            return False

    # Filter out GitHub Actions (e.g. actions/checkout@v4)
    if img_lower.startswith('actions/') or img_lower.startswith('github/'):
        return False

    if ' ' in img_stripped or '\t' in img_stripped or '\n' in img_stripped or '=' in img_stripped:
        return False
    if not re.search(r'[a-zA-Z0-9]', img_stripped):
        return False

    # Filter out standalone host:port without path (e.g. localhost:5000 or 127.0.0.1:8080)
    if (img_stripped.startswith('localhost:') or img_stripped.startswith('127.0.0.1:')) and '/' not in img_stripped:
        return False

    # Must contain a tag, a digest, or a slash
    if ':' not in img_stripped and '@' not in img_stripped and '/' not in img_stripped:
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

    if is_unresolved_dynamic_ref(image_ref) or image_ref.startswith(":") or not image_ref:
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

def resolve_arg_variables(raw_value: str, args_env: dict) -> str:
    result = raw_value
    def sub_func(match):
        var_expr = match.group(1) or match.group(2)
        if ':-' in var_expr:
            v_name, v_default = var_expr.split(':-', 1)
            val = args_env.get(v_name, v_default)
            return val if val else f"${{{var_expr}}}"
        val = args_env.get(var_expr, "")
        if val:
            return val
        return match.group(0)

    result = re.sub(r'\$\{([^}]+)\}|\$([a-zA-Z_][a-zA-Z0-9_]*)', sub_func, result)
    return result

def parse_dockerfile(filepath: Path) -> tuple:
    images = []
    unresolved_dynamics = []
    args_env = {}
    stage_names = set()

    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            lines = f.readlines()

        for line_no, raw_line in enumerate(lines, 1):
            line = raw_line.strip()
            if line.startswith('#'):
                continue

            if line.upper().startswith('ARG '):
                arg_part = line[4:].strip()
                if '=' in arg_part:
                    k, v = arg_part.split('=', 1)
                    k = k.strip()
                    v = v.strip().strip('"').strip("'")
                    args_env[k] = v
                else:
                    k = arg_part.strip()
                    if k not in args_env:
                        args_env[k] = ""

            elif line.upper().startswith('FROM '):
                parts = line.split()
                if len(parts) >= 2:
                    raw_img = parts[1]
                    if len(parts) >= 4 and parts[2].upper() == 'AS':
                        stage_names.add(parts[3].lower())

                    resolved_img = resolve_arg_variables(raw_img, args_env)

                    if raw_img.lower() == 'scratch':
                        continue

                    if is_unresolved_dynamic_ref(resolved_img):
                        var_match = re.search(r'\$\{?([a-zA-Z_][a-zA-Z0-9_]*)\}?', raw_img)
                        var_name = var_match.group(1) if var_match else raw_img
                        unresolved_dynamics.append({
                            'image': raw_img,
                            'variable_name': var_name,
                            'from_expression': line,
                            'line': line_no,
                            'context': 'FROM_ARG'
                        })
                    elif is_valid_image_ref(resolved_img) and resolved_img.lower() not in stage_names:
                        images.append({
                            'image': resolved_img,
                            'line': line_no,
                            'context': 'FROM'
                        })

            elif '--from=' in line:
                match = re.search(r'--from=([^\s]+)', line)
                if match:
                    raw_img = match.group(1)
                    resolved_img = resolve_arg_variables(raw_img, args_env)
                    if is_unresolved_dynamic_ref(resolved_img):
                        var_match = re.search(r'\$\{?([a-zA-Z_][a-zA-Z0-9_]*)\}?', raw_img)
                        var_name = var_match.group(1) if var_match else raw_img
                        unresolved_dynamics.append({
                            'image': raw_img,
                            'variable_name': var_name,
                            'from_expression': line,
                            'line': line_no,
                            'context': 'COPY_FROM_ARG'
                        })
                    elif is_valid_image_ref(resolved_img) and not resolved_img.isdigit() and resolved_img.lower() not in stage_names:
                        images.append({
                            'image': resolved_img,
                            'line': line_no,
                            'context': 'COPY --from'
                        })
    except Exception as e:
        sys.stderr.write(f"Error reading {filepath}: {e}\n")

    return images, unresolved_dynamics

def extract_images_from_yaml_obj(obj, context="yaml", images_acc=None, unresolved_acc=None):
    if images_acc is None:
        images_acc = []
    if unresolved_acc is None:
        unresolved_acc = []

    if isinstance(obj, dict):
        if 'image' in obj and isinstance(obj['image'], str):
            img = obj['image'].strip()
            if is_unresolved_dynamic_ref(img):
                var_match = re.search(r'\$\{?([a-zA-Z_][a-zA-Z0-9_]*)\}?|\{\{\s*([a-zA-Z0-9_.-]+)\s*\}\}', img)
                var_name = (var_match.group(1) or var_match.group(2)) if var_match else img
                unresolved_acc.append({
                    'image': img,
                    'variable_name': var_name,
                    'from_expression': f"yaml: {img}",
                    'context': context
                })
            elif is_valid_image_ref(img):
                images_acc.append({'image': img, 'context': context})

        if 'repository' in obj and isinstance(obj['repository'], str):
            repo = obj['repository'].strip()
            tag = obj.get('tag', '')
            if is_unresolved_dynamic_ref(repo) or (isinstance(tag, str) and is_unresolved_dynamic_ref(tag)):
                unresolved_acc.append({
                    'image': f"{repo}:{tag}",
                    'variable_name': repo,
                    'from_expression': f"repository: {repo}, tag: {tag}",
                    'context': f"{context}.repository+tag"
                })
            elif is_valid_image_ref(repo):
                if isinstance(tag, (str, int, float)):
                    tag_str = str(tag).strip()
                    full_img = f"{repo}:{tag_str}" if tag_str and not tag_str.startswith('http') else repo
                else:
                    full_img = repo
                if is_valid_image_ref(full_img):
                    images_acc.append({'image': full_img, 'context': f"{context}.repository+tag"})

        for k, v in obj.items():
            extract_images_from_yaml_obj(v, f"{context}.{k}", images_acc, unresolved_acc)
    elif isinstance(obj, list):
        for idx, item in enumerate(obj):
            extract_images_from_yaml_obj(item, f"{context}[{idx}]", images_acc, unresolved_acc)

    return images_acc, unresolved_acc

def parse_yaml_file(filepath: Path) -> tuple:
    images = []
    unresolved = []
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
            docs = yaml.safe_load_all(content)
            for doc in docs:
                if doc:
                    extract_images_from_yaml_obj(doc, "yaml", images, unresolved)
    except Exception:
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                for line_no, line in enumerate(f, 1):
                    match = re.search(r'image:\s*["\']?([^\s"\'#]+)', line)
                    if match:
                        img = match.group(1).strip()
                        if is_unresolved_dynamic_ref(img):
                            unresolved.append({
                                'image': img,
                                'variable_name': img,
                                'from_expression': line.strip(),
                                'line': line_no,
                                'context': f'line:{line_no}'
                            })
                        elif is_valid_image_ref(img):
                            images.append({'image': img, 'context': f'line:{line_no}'})
        except Exception:
            pass
    return images, unresolved

def parse_code_or_script_file(filepath: Path) -> tuple:
    images = []
    unresolved = []
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            for line_no, line in enumerate(f, 1):
                if 'uses:' in line or 'curl' in line or 'wget' in line or 'http://' in line or 'https://' in line:
                    continue
                words = re.split(r'[\s"\'`=,]+', line.strip())
                for tok in words:
                    tok = tok.strip()
                    if is_unresolved_dynamic_ref(tok):
                        unresolved.append({
                            'image': tok,
                            'variable_name': tok,
                            'from_expression': line.strip(),
                            'line': line_no,
                            'context': f'script_line:{line_no}'
                        })
                    elif is_valid_image_ref(tok):
                        images.append({'image': tok, 'context': f'script_line:{line_no}'})
    except Exception:
        pass
    return images, unresolved

def discover_all(repo_root: Path):
    dockerfiles_found = set()
    discovered_images = {}
    unresolved_dynamic_images = []
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

            extracted_images = []
            extracted_unresolved = []

            if file.startswith('Dockerfile') or file.startswith('Containerfile'):
                extracted_images, extracted_unresolved = parse_dockerfile(full_path)
            elif file.endswith('.yaml') or file.endswith('.yml'):
                extracted_images, extracted_unresolved = parse_yaml_file(full_path)
            elif file.endswith('.sh') or file.endswith('.py') or rel_path.startswith('.github/'):
                extracted_images, extracted_unresolved = parse_code_or_script_file(full_path)

            for unres in extracted_unresolved:
                unres['source_path'] = rel_path
                unresolved_dynamic_images.append(unres)

            for item in extracted_images:
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

    return list(discovered_images.values()), sorted(dockerfile_list), unresolved_dynamic_images

def main():
    parser = argparse.ArgumentParser(description="Discover image references across repository.")
    parser.add_argument("--repo-root", default=".", help="Repository root path")
    parser.add_argument("--output", default=None, help="Output JSON file path")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    images, dockerfiles, unresolved_dynamics = discover_all(repo_root)

    result = {
        'dockerfiles': dockerfiles,
        'image_count': len(images),
        'unresolved_dynamic_count': len(unresolved_dynamics),
        'images': images,
        'unresolved_dynamic_images': unresolved_dynamics
    }

    out_json = json.dumps(result, indent=2)
    if args.output:
        with open(args.output, 'w', encoding='utf-8') as f:
            f.write(out_json)
    else:
        print(out_json)

if __name__ == '__main__':
    main()
