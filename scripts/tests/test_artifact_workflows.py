"""Tests for scripts/ci/artifact_matrix.py — matrix builder for image-mirror.yml
and helm-mirror.yml.

Tests cover meaningful boundaries only:
- Empty manifest / empty filter result → has_images/has_charts = false, matrix = []
- Normal filtering by substring (source, target, chart name)
- Matrix output shape (only source+target keys in image entries)
- acr_path traversal validation: '..' and leading '/' rejected
- GITHUB_OUTPUT file writing vs stdout fallback
- CLI entry point returns correct exit code
"""

from __future__ import annotations

import importlib
import json
import os
import sys
import tempfile
import textwrap
import types

import pytest

# ── Import the module under test ──────────────────────────────────────────────
# Add scripts/ to path so the module is importable without installation.
_SCRIPTS_DIR = os.path.join(os.path.dirname(__file__), "..", "ci")
sys.path.insert(0, os.path.abspath(_SCRIPTS_DIR))

import artifact_matrix as am  # noqa: E402  (path manipulation above is intentional)


# ── Fixtures ──────────────────────────────────────────────────────────────────

SAMPLE_DATA: dict = {
    "images": [
        {"source": "quay.io/argoproj/argocd:v3.5.5", "target": "argoproj/argocd:v3.5.5"},
        {"source": "ghcr.io/external-secrets/external-secrets:v2.13.0", "target": "external-secrets/external-secrets:v2.13.0"},
        {"source": "redis:7.4.11-alpine", "target": "redis:7.4.11-alpine"},
    ],
    "helm_charts": [
        {"name": "argo-cd", "repo": "https://argoproj.github.io/argo-helm", "version": "10.10.5", "acr_path": "helm"},
        {"name": "external-secrets", "repo": "https://charts.external-secrets.io", "version": "0.13.0", "acr_path": "helm"},
        {"name": "cert-manager", "repo": "https://charts.jetstack.io", "version": "v1.21.2", "acr_path": "helm"},
    ],
}


# ── validate_acr_path ─────────────────────────────────────────────────────────

class TestValidateAcrPath:
    def test_valid_path_passes(self):
        assert am.validate_acr_path("helm") == "helm"

    def test_valid_nested_path_passes(self):
        assert am.validate_acr_path("oci/charts") == "oci/charts"

    def test_dotdot_rejected(self):
        with pytest.raises(ValueError, match="traversal"):
            am.validate_acr_path("helm/../..")

    def test_dotdot_in_middle_rejected(self):
        with pytest.raises(ValueError, match="traversal"):
            am.validate_acr_path("helm/../evil")

    def test_leading_slash_rejected(self):
        with pytest.raises(ValueError, match="relative"):
            am.validate_acr_path("/helm")

    def test_empty_string_passes(self):
        # Empty acr_path is allowed by validate_acr_path (chart manifest
        # validation is the caller's responsibility).
        assert am.validate_acr_path("") == ""


# ── build_image_matrix ────────────────────────────────────────────────────────

class TestBuildImageMatrix:
    def test_no_filter_returns_all(self):
        matrix, has = am.build_image_matrix(SAMPLE_DATA, "")
        assert has is True
        assert len(matrix["include"]) == 3

    def test_entries_contain_only_source_and_target(self):
        """Matrix entries must expose exactly source + target — no extra keys."""
        matrix, _ = am.build_image_matrix(SAMPLE_DATA, "")
        for entry in matrix["include"]:
            assert set(entry.keys()) == {"source", "target"}

    def test_filter_by_source_substring(self):
        matrix, has = am.build_image_matrix(SAMPLE_DATA, "argoproj")
        assert has is True
        assert len(matrix["include"]) == 1
        assert matrix["include"][0]["source"] == "quay.io/argoproj/argocd:v3.5.5"

    def test_filter_by_target_substring(self):
        matrix, has = am.build_image_matrix(SAMPLE_DATA, "redis")
        assert has is True
        assert len(matrix["include"]) == 1
        assert matrix["include"][0]["target"] == "redis:7.4.11-alpine"

    def test_filter_no_match_returns_empty(self):
        matrix, has = am.build_image_matrix(SAMPLE_DATA, "nonexistent-image-xyz")
        assert has is False
        assert matrix == {"include": []}

    def test_empty_manifest_returns_empty(self):
        matrix, has = am.build_image_matrix({}, "")
        assert has is False
        assert matrix == {"include": []}

    def test_null_images_key_treated_as_empty(self):
        matrix, has = am.build_image_matrix({"images": None}, "")
        assert has is False

    def test_matrix_json_is_valid(self):
        """matrix must be round-trippable through json.dumps/loads."""
        matrix, _ = am.build_image_matrix(SAMPLE_DATA, "")
        parsed = json.loads(json.dumps(matrix))
        assert parsed["include"] == matrix["include"]


# ── build_chart_matrix ────────────────────────────────────────────────────────

class TestBuildChartMatrix:
    def test_no_filter_returns_all(self):
        matrix, has = am.build_chart_matrix(SAMPLE_DATA, "")
        assert has is True
        assert len(matrix["include"]) == 3

    def test_filter_by_name(self):
        matrix, has = am.build_chart_matrix(SAMPLE_DATA, "argo")
        assert has is True
        assert len(matrix["include"]) == 1
        assert matrix["include"][0]["name"] == "argo-cd"

    def test_filter_no_match(self):
        matrix, has = am.build_chart_matrix(SAMPLE_DATA, "nosuchchart")
        assert has is False
        assert matrix == {"include": []}

    def test_empty_manifest(self):
        matrix, has = am.build_chart_matrix({}, "")
        assert has is False

    def test_null_helm_charts_key(self):
        matrix, has = am.build_chart_matrix({"helm_charts": None}, "")
        assert has is False

    def test_traversal_in_acr_path_raises(self):
        bad_data = {
            "helm_charts": [
                {"name": "evil", "repo": "https://example.com", "version": "1.0.0", "acr_path": "helm/../.."},
            ]
        }
        with pytest.raises(ValueError, match="traversal"):
            am.build_chart_matrix(bad_data, "")

    def test_leading_slash_in_acr_path_raises(self):
        bad_data = {
            "helm_charts": [
                {"name": "evil", "repo": "https://example.com", "version": "1.0.0", "acr_path": "/helm"},
            ]
        }
        with pytest.raises(ValueError, match="relative"):
            am.build_chart_matrix(bad_data, "")

    def test_chart_entries_preserved_verbatim(self):
        """build_chart_matrix must not strip chart-specific keys (repo, version…)."""
        matrix, _ = am.build_chart_matrix(SAMPLE_DATA, "cert-manager")
        entry = matrix["include"][0]
        assert entry["repo"] == "https://charts.jetstack.io"
        assert entry["version"] == "v1.21.2"
        assert entry["acr_path"] == "helm"


# ── write_github_outputs ──────────────────────────────────────────────────────

class TestWriteGithubOutputs:
    def test_writes_to_file_when_env_set(self, tmp_path):
        out_file = tmp_path / "output"
        out_file.touch()
        env = os.environ.copy()
        env["GITHUB_OUTPUT"] = str(out_file)

        original = os.environ.get("GITHUB_OUTPUT")
        try:
            os.environ["GITHUB_OUTPUT"] = str(out_file)
            am.write_github_outputs({"matrix": '{"include":[]}', "has_images": "false"})
        finally:
            if original is None:
                os.environ.pop("GITHUB_OUTPUT", None)
            else:
                os.environ["GITHUB_OUTPUT"] = original

        content = out_file.read_text()
        assert "matrix=" in content
        assert "has_images=false" in content

    def test_falls_back_to_stdout_when_no_env(self, capsys):
        original = os.environ.pop("GITHUB_OUTPUT", None)
        try:
            am.write_github_outputs({"has_charts": "true"})
        finally:
            if original is not None:
                os.environ["GITHUB_OUTPUT"] = original

        out = capsys.readouterr().out
        assert "has_charts=true" in out

    def test_json_is_not_shell_interpolated(self, tmp_path):
        """Matrix JSON must reach the output file verbatim — no shell quoting."""
        out_file = tmp_path / "output"
        out_file.touch()
        matrix_json = json.dumps({"include": [{"source": "a:1", "target": "b:1"}]})

        original = os.environ.get("GITHUB_OUTPUT")
        try:
            os.environ["GITHUB_OUTPUT"] = str(out_file)
            am.write_github_outputs({"matrix": matrix_json})
        finally:
            if original is None:
                os.environ.pop("GITHUB_OUTPUT", None)
            else:
                os.environ["GITHUB_OUTPUT"] = original

        content = out_file.read_text()
        # Line must be exactly  matrix=<JSON>\n  — no extra quoting/escaping
        assert f"matrix={matrix_json}\n" in content


# ── CLI entry point ───────────────────────────────────────────────────────────

class TestCLI:
    """End-to-end CLI tests using a temporary YAML file."""

    @pytest.fixture()
    def yaml_file(self, tmp_path):
        import yaml
        path = tmp_path / "images-to-mirror.yaml"
        path.write_text(
            textwrap.dedent("""
                images:
                  - source: quay.io/argoproj/argocd:v3.5.5
                    target: argoproj/argocd:v3.5.5
                helm_charts:
                  - name: argo-cd
                    repo: https://argoproj.github.io/argo-helm
                    version: "10.10.5"
                    acr_path: helm
            """),
            encoding="utf-8",
        )
        return str(path)

    def test_images_command_zero_exit(self, yaml_file, tmp_path):
        out_file = tmp_path / "gh_output"
        out_file.touch()
        original = os.environ.get("GITHUB_OUTPUT")
        try:
            os.environ["GITHUB_OUTPUT"] = str(out_file)
            rc = am.main(["images", "--input", yaml_file])
        finally:
            if original is None:
                os.environ.pop("GITHUB_OUTPUT", None)
            else:
                os.environ["GITHUB_OUTPUT"] = original
        assert rc == 0

    def test_charts_command_zero_exit(self, yaml_file, tmp_path):
        out_file = tmp_path / "gh_output"
        out_file.touch()
        original = os.environ.get("GITHUB_OUTPUT")
        try:
            os.environ["GITHUB_OUTPUT"] = str(out_file)
            rc = am.main(["charts", "--input", yaml_file])
        finally:
            if original is None:
                os.environ.pop("GITHUB_OUTPUT", None)
            else:
                os.environ["GITHUB_OUTPUT"] = original
        assert rc == 0

    def test_images_filter_no_match_zero_exit(self, yaml_file, tmp_path):
        """No match is not an error — has_images=false and exit 0."""
        out_file = tmp_path / "gh_output"
        out_file.touch()
        original = os.environ.get("GITHUB_OUTPUT")
        try:
            os.environ["GITHUB_OUTPUT"] = str(out_file)
            rc = am.main(["images", "--input", yaml_file, "--filter", "nonexistent"])
        finally:
            if original is None:
                os.environ.pop("GITHUB_OUTPUT", None)
            else:
                os.environ["GITHUB_OUTPUT"] = original
        assert rc == 0
        content = out_file.read_text()
        assert "has_images=false" in content

    def test_charts_traversal_exits_nonzero(self, tmp_path):
        bad_yaml = tmp_path / "bad.yaml"
        bad_yaml.write_text(
            textwrap.dedent("""
                helm_charts:
                  - name: evil
                    repo: https://example.com
                    version: "1.0.0"
                    acr_path: "helm/../.."
            """),
            encoding="utf-8",
        )
        out_file = tmp_path / "gh_output"
        out_file.touch()
        original = os.environ.get("GITHUB_OUTPUT")
        try:
            os.environ["GITHUB_OUTPUT"] = str(out_file)
            rc = am.main(["charts", "--input", str(bad_yaml)])
        finally:
            if original is None:
                os.environ.pop("GITHUB_OUTPUT", None)
            else:
                os.environ["GITHUB_OUTPUT"] = original
        assert rc != 0
