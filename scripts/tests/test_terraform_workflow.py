"""Unit tests for ``scripts/ci/terraform_plan_guard.py`` — the trust boundary
between the Bootstrap Azure *plan* job and the *apply* / *destroy* jobs.

These are fast and hermetic: they exercise only the guard module (stdlib +
``cryptography`` for AES-GCM — the same dependency the workflow installs) and
operate entirely on temp files. No Azure/GitHub APIs, no network, no ``opa``
binary required (OPA invocation is faked with a stub executable).

Run locally:
    cd scripts
    python -m pytest tests/test_terraform_workflow.py -q
"""

from __future__ import annotations

import importlib.util
import json
import os
import stat
import sys
from pathlib import Path

import pytest

CI_DIR = Path(__file__).resolve().parent.parent / "ci"


def _load_guard():
    """Import terraform_plan_guard.py by path (it is a script, not a package)."""
    spec = importlib.util.spec_from_file_location(
        "terraform_plan_guard", CI_DIR / "terraform_plan_guard.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


guard = _load_guard()

# ``cryptography`` is required for seal/open; skip those tests cleanly if the
# runner's Python lacks it rather than erroring on import.
try:  # noqa: SIM105
    import cryptography  # noqa: F401

    HAS_CRYPTO = True
except ImportError:
    HAS_CRYPTO = False

requires_crypto = pytest.mark.skipif(
    not HAS_CRYPTO, reason="cryptography package not installed"
)

KEY = "unit-test-master-key-not-a-real-secret"


@pytest.fixture()
def workspace(tmp_path, monkeypatch):
    """A temp dir with a fake saved plan + PLAN_ENCRYPTION_KEY set."""
    monkeypatch.setenv("PLAN_ENCRYPTION_KEY", KEY)
    monkeypatch.chdir(tmp_path)
    plan = tmp_path / "tfplan"
    plan.write_bytes(b"\x00binary terraform plan bytes\x01")
    return tmp_path


def _bind(**overrides):
    argv = [
        "bind",
        "--plan",
        "tfplan",
        "--manifest",
        "tfplan.binding.json",
        "--environment",
        overrides.get("environment", "dev"),
        "--sha",
        overrides.get("sha", "a" * 40),
        "--mode",
        overrides.get("mode", "apply"),
        "--run-id",
        overrides.get("run_id", "123"),
        "--run-attempt",
        overrides.get("run_attempt", "1"),
    ]
    return guard.main(argv)


def _seal(environment="dev"):
    return guard.main(
        [
            "seal",
            "--plan",
            "tfplan",
            "--manifest",
            "tfplan.binding.json",
            "--environment",
            environment,
            "--out",
            "tfplan.sealed",
        ]
    )


def _open(out="tfplan.out", **overrides):
    argv = [
        "open",
        "--sealed",
        "tfplan.sealed",
        "--out",
        out,
        "--environment",
        overrides.get("environment", "dev"),
        "--sha",
        overrides.get("sha", "a" * 40),
        "--mode",
        overrides.get("mode", "apply"),
    ]
    if "max_age_seconds" in overrides:
        argv += ["--max-age-seconds", str(overrides["max_age_seconds"])]
    return guard.main(argv)


# ---------------------------------------------------------------------------
# Key handling
# ---------------------------------------------------------------------------
def test_missing_key_is_fatal(tmp_path, monkeypatch):
    monkeypatch.delenv("PLAN_ENCRYPTION_KEY", raising=False)
    monkeypatch.chdir(tmp_path)
    (tmp_path / "tfplan").write_bytes(b"x")
    with pytest.raises(SystemExit):
        _bind()


# ---------------------------------------------------------------------------
# Binding manifest
# ---------------------------------------------------------------------------
def test_bind_writes_signed_manifest(workspace):
    assert _bind() == 0
    manifest = json.loads((workspace / "tfplan.binding.json").read_text())
    assert manifest["payload"]["environment"] == "dev"
    assert manifest["payload"]["mode"] == "apply"
    assert manifest["payload"]["sha"] == "a" * 40
    assert manifest["payload"]["plan_sha256"]
    assert manifest["signature"]


def test_bind_rejects_invalid_mode(workspace):
    # argparse choices reject it before our own check.
    with pytest.raises(SystemExit):
        _bind(mode="nuke")


def test_bind_fails_when_plan_missing(workspace):
    (workspace / "tfplan").unlink()
    with pytest.raises(SystemExit):
        _bind()


# ---------------------------------------------------------------------------
# Seal / open round trip
# ---------------------------------------------------------------------------
@requires_crypto
def test_seal_open_roundtrip(workspace):
    original = (workspace / "tfplan").read_bytes()
    assert _bind() == 0
    assert _seal() == 0
    sealed = json.loads((workspace / "tfplan.sealed").read_text())
    # Plan bytes must NOT appear in cleartext in the sealed artifact.
    assert b"binary terraform plan bytes" not in (workspace / "tfplan.sealed").read_bytes()
    assert sealed["schema"] == "tfplan-sealed/1"
    assert _open() == 0
    assert (workspace / "tfplan.out").read_bytes() == original


@requires_crypto
def test_open_rejects_wrong_environment(workspace):
    assert _bind(environment="dev") == 0
    assert _seal(environment="dev") == 0
    with pytest.raises(SystemExit):
        _open(environment="prod")


@requires_crypto
def test_open_rejects_wrong_sha(workspace):
    assert _bind(sha="a" * 40) == 0
    assert _seal() == 0
    with pytest.raises(SystemExit):
        _open(sha="b" * 40)


@requires_crypto
def test_open_rejects_wrong_mode(workspace):
    assert _bind(mode="apply") == 0
    assert _seal() == 0
    with pytest.raises(SystemExit):
        _open(mode="destroy")


@requires_crypto
def test_open_rejects_stale_plan(workspace):
    assert _bind() == 0
    assert _seal() == 0
    # A plan older than the (0s) freshness window must be refused.
    with pytest.raises(SystemExit):
        _open(max_age_seconds=0)


@requires_crypto
def test_open_rejects_tampered_ciphertext(workspace):
    assert _bind() == 0
    assert _seal() == 0
    sealed_path = workspace / "tfplan.sealed"
    sealed = json.loads(sealed_path.read_text())
    # Flip a byte in the ciphertext → AEAD auth must fail.
    import base64

    ct = bytearray(base64.b64decode(sealed["ciphertext"]))
    ct[0] ^= 0xFF
    sealed["ciphertext"] = base64.b64encode(bytes(ct)).decode("ascii")
    sealed_path.write_text(json.dumps(sealed))
    with pytest.raises(SystemExit):
        _open()


@requires_crypto
def test_open_rejects_wrong_key(workspace, monkeypatch):
    assert _bind() == 0
    assert _seal() == 0
    monkeypatch.setenv("PLAN_ENCRYPTION_KEY", "a-completely-different-master-key")
    with pytest.raises(SystemExit):
        _open()


# ---------------------------------------------------------------------------
# OPA package discovery + evaluation (fake opa binary)
# ---------------------------------------------------------------------------
def _write_policies(root: Path) -> Path:
    policies = root / "policies"
    policies.mkdir()
    (policies / "a.rego").write_text("package terraform.azure.alpha\n\ndeny := []\n")
    (policies / "b.rego").write_text("package terraform.azure.beta\n\ndeny := []\n")
    # A second file sharing a package name must not double-count.
    (policies / "a_more.rego").write_text(
        "package terraform.azure.alpha\n\nother := true\n"
    )
    return policies


def test_discover_packages_dedups_and_sorts(tmp_path):
    policies = _write_policies(tmp_path)
    packages = guard._discover_packages(policies)
    assert packages == ["terraform.azure.alpha", "terraform.azure.beta"]


def _fake_opa(tmp_path: Path, *, denies_for: dict[str, list[str]]) -> Path:
    """Create a stub `opa` executable that returns canned deny results.

    It reads the query (last arg, e.g. ``data.terraform.azure.alpha.deny``) and
    emits an OPA-eval-shaped JSON document with the configured deny list.
    """
    script = tmp_path / "fake-opa"
    payload = json.dumps(denies_for)
    script.write_text(
        "#!/usr/bin/env python3\n"
        "import json, sys\n"
        f"DENIES = json.loads({payload!r})\n"
        "query = sys.argv[-1]\n"
        "pkg = query[len('data.'):-len('.deny')]\n"
        "vals = DENIES.get(pkg, [])\n"
        "print(json.dumps({'result': [{'expressions': [{'value': vals}]}]}))\n"
    )
    script.chmod(script.stat().st_mode | stat.S_IEXEC | stat.S_IRUSR)
    return script


def test_opa_passes_when_no_denies(tmp_path, capsys):
    policies = _write_policies(tmp_path)
    plan_json = tmp_path / "tfplan.json"
    plan_json.write_text("{}")
    opa_bin = _fake_opa(tmp_path, denies_for={})
    rc = guard.main(
        [
            "opa",
            "--policies",
            str(policies),
            "--plan-json",
            str(plan_json),
            "--opa-bin",
            str(opa_bin),
        ]
    )
    assert rc == 0
    out = capsys.readouterr().out
    assert "All 2 policy package(s) passed" in out


def test_opa_fails_on_any_package_deny(tmp_path):
    policies = _write_policies(tmp_path)
    plan_json = tmp_path / "tfplan.json"
    plan_json.write_text("{}")
    opa_bin = _fake_opa(
        tmp_path,
        denies_for={"terraform.azure.beta": ["DENY [Beta] bad thing"]},
    )
    with pytest.raises(SystemExit):
        guard.main(
            [
                "opa",
                "--policies",
                str(policies),
                "--plan-json",
                str(plan_json),
                "--opa-bin",
                str(opa_bin),
            ]
        )


def test_opa_fails_when_no_packages(tmp_path):
    empty = tmp_path / "policies"
    empty.mkdir()
    plan_json = tmp_path / "tfplan.json"
    plan_json.write_text("{}")
    with pytest.raises(SystemExit):
        guard.main(
            [
                "opa",
                "--policies",
                str(empty),
                "--plan-json",
                str(plan_json),
                "--opa-bin",
                "opa",
            ]
        )


def test_opa_fails_when_plan_json_missing(tmp_path):
    policies = _write_policies(tmp_path)
    with pytest.raises(SystemExit):
        guard.main(
            [
                "opa",
                "--policies",
                str(policies),
                "--plan-json",
                str(tmp_path / "nope.json"),
                "--opa-bin",
                "opa",
            ]
        )
