#!/usr/bin/env python3
"""
policy.py

Shared, validated policy-loader for supply-chain sentinel tools.
Loads .supply-chain/policy.yaml and enforces strict schema validation, failing
closed if required fields are missing, malformed, or improperly typed.
"""

import sys
import os
import re
from pathlib import Path, PurePath
import fnmatch
import yaml

VALID_SEVERITIES = {"CRITICAL", "HIGH", "MEDIUM", "LOW", "NEGLIGIBLE", "UNKNOWN"}

class PolicyError(ValueError):
    """Raised when policy configuration is missing, malformed, or invalid."""
    pass

def load_policy(policy_path=None, repo_root=None) -> dict:
    if repo_root is None:
        repo_root = Path(".").resolve()
    else:
        repo_root = Path(repo_root).resolve()

    if policy_path is None:
        candidate_1 = repo_root / ".supply-chain" / "policy.yaml"
        main_repo_root = Path(__file__).resolve().parent.parent.parent
        candidate_2 = main_repo_root / ".supply-chain" / "policy.yaml"

        if candidate_1.exists():
            policy_path = candidate_1
        elif candidate_2.exists():
            policy_path = candidate_2
        else:
            raise PolicyError(f"Policy file not found at {candidate_1} or {candidate_2}. Failing closed.")
    else:
        policy_path = Path(policy_path).resolve()
        if not policy_path.exists():
            raise PolicyError(f"Policy file not found at {policy_path}. Failing closed.")

    try:
        with open(policy_path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
    except Exception as e:
        raise PolicyError(f"Failed to parse YAML from {policy_path}: {e}")

    if not isinstance(data, dict):
        raise PolicyError(f"Policy file {policy_path} must contain a top-level YAML dictionary.")

    # 1. Validate target_platforms
    target_platforms = data.get("target_platforms")
    if not isinstance(target_platforms, list) or not target_platforms:
        raise PolicyError("Policy missing or invalid required field 'target_platforms' (must be non-empty list).")
    for plat in target_platforms:
        if not isinstance(plat, str) or "/" not in plat:
            raise PolicyError(f"Invalid platform entry '{plat}' in target_platforms. Must be 'os/arch'.")

    # 2. Validate vulnerability_policy
    vuln_policy = data.get("vulnerability_policy")
    if not isinstance(vuln_policy, dict):
        raise PolicyError("Policy missing or invalid required dict 'vulnerability_policy'.")

    fail_on = vuln_policy.get("fail_on_severity")
    if not isinstance(fail_on, list):
        raise PolicyError("Policy missing or invalid 'vulnerability_policy.fail_on_severity' (must be a list).")
    for sev in fail_on:
        if not isinstance(sev, str) or sev.upper() not in VALID_SEVERITIES:
            raise PolicyError(f"Invalid severity '{sev}' in vulnerability_policy.fail_on_severity.")

    ignore_unfixed = vuln_policy.get("ignore_unfixed")
    if not isinstance(ignore_unfixed, bool):
        raise PolicyError("Policy missing or invalid boolean 'vulnerability_policy.ignore_unfixed'. String coercions strictly rejected.")

    # 3. Validate first_party
    first_party = data.get("first_party")
    if not isinstance(first_party, dict):
        raise PolicyError("Policy missing or invalid required dict 'first_party'.")

    df_paths = first_party.get("dockerfile_paths")
    if not isinstance(df_paths, list):
        raise PolicyError("Policy missing or invalid 'first_party.dockerfile_paths' (must be a list).")

    img_patterns = first_party.get("image_patterns")
    if not isinstance(img_patterns, list):
        raise PolicyError("Policy missing or invalid 'first_party.image_patterns' (must be a list).")

    # 4. Validate helm_policy
    helm_policy = data.get("helm_policy")
    if not isinstance(helm_policy, dict):
        raise PolicyError("Policy missing or invalid required dict 'helm_policy'.")

    class_patterns = helm_policy.get("classification_patterns")
    if not isinstance(class_patterns, dict):
        raise PolicyError("Policy missing or invalid 'helm_policy.classification_patterns' (must be a dict).")

    # Strict boolean validation without bool(...) string coercion
    req_lock = helm_policy.get("require_chart_lock_if_dependencies", True)
    if not isinstance(req_lock, bool):
        raise PolicyError("Policy field 'helm_policy.require_chart_lock_if_dependencies' must be an explicit YAML boolean. String coercions strictly rejected.")

    allow_main = helm_policy.get("allow_protected_git_main", True)
    if not isinstance(allow_main, bool):
        raise PolicyError("Policy field 'helm_policy.allow_protected_git_main' must be an explicit YAML boolean. String coercions strictly rejected.")

    # 5. Validate registries
    registries = data.get("registries", {})
    if not isinstance(registries, dict):
        raise PolicyError("Policy field 'registries' must be a dictionary.")

    container_reg = registries.get("container_registry", "ghcr.io/amediomediagroup")
    helm_oci_reg = registries.get("helm_oci_registry", "ghcr.io/amediomediagroup/charts")
    if not isinstance(container_reg, str) or not container_reg.strip():
        raise PolicyError("Policy field 'registries.container_registry' must be a non-empty string.")
    if not isinstance(helm_oci_reg, str) or not helm_oci_reg.strip():
        raise PolicyError("Policy field 'registries.helm_oci_registry' must be a non-empty string.")

    return {
        "version": str(data.get("version", "1.0")),
        "registries": {
            "container_registry": container_reg.strip(),
            "helm_oci_registry": helm_oci_reg.strip()
        },
        "target_platforms": target_platforms,
        "vulnerability_policy": {
            "fail_on_severity": [s.upper() for s in fail_on],
            "ignore_unfixed": ignore_unfixed
        },
        "first_party": {
            "dockerfile_paths": df_paths, # VALIDATED_BUT_NOT_YET_CONSUMED (build-source coverage metadata)
            "image_patterns": img_patterns
        },
        "helm_policy": {
            "classification_patterns": class_patterns,
            "require_chart_lock_if_dependencies": req_lock,
            "allow_protected_git_main": allow_main
        },
        "provenance_policy": data.get("provenance_policy", {})
    }

def match_glob_pattern(pattern: str, path_str: str) -> bool:
    """Standard deterministic path/glob matching supporting recursive ** patterns."""
    norm_path = Path(path_str.replace("\\", "/"))
    norm_pat = pattern.replace("\\", "/")

    if norm_path.match(norm_pat):
        return True

    if norm_pat.endswith("/**"):
        base_prefix = norm_pat[:-3]
        if str(norm_path).startswith(base_prefix + "/") or str(norm_path) == base_prefix:
            return True
    elif norm_pat.endswith("/*"):
        base_prefix = norm_pat[:-2]
        if str(norm_path).startswith(base_prefix + "/") or str(norm_path) == base_prefix:
            return True

    return False

def classify_image_ownership(image_ref: str, source_paths: list, dockerfiles_found: set, policy: dict) -> str:
    image_patterns = policy["first_party"]["image_patterns"]

    for pattern in image_patterns:
        if re.search(pattern, image_ref) or match_glob_pattern(pattern, image_ref):
            return "FIRST_PARTY_IMAGE"

    if "${" in image_ref or "{{" in image_ref or image_ref.startswith(":") or not image_ref:
        return "UNKNOWN"

    return "THIRD_PARTY_IMAGE"

def classify_helm_chart(rel_path: str, policy: dict) -> str:
    patterns_map = policy["helm_policy"]["classification_patterns"]
    path_str = rel_path.replace("\\", "/")

    for category, patterns in patterns_map.items():
        if isinstance(patterns, list):
            for pat in patterns:
                if match_glob_pattern(pat, path_str):
                    return category.upper()

    return "UNKNOWN"

if __name__ == "__main__":
    try:
        pol = load_policy()
        print(f"Policy loaded successfully. Target platforms: {pol['target_platforms']}")
    except Exception as ex:
        print(f"Policy load failed closed: {ex}", file=sys.stderr)
        sys.exit(1)
