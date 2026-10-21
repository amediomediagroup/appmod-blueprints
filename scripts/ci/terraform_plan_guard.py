#!/usr/bin/env python3
"""Terraform plan artifact guard for the Bootstrap Azure CI/CD pipeline.

This helper is the trust boundary between the *plan* job (which runs on
trusted ``main`` / dispatch events and produces a saved Terraform plan) and
the *apply* / *destroy* jobs (which consume that saved plan). It never talks
to Azure or GitHub APIs and takes no free-form shell input — every value is
passed as an explicit CLI argument or environment variable, so there is no
shell / template interpolation of untrusted data.

Responsibilities
----------------
``bind``     Write a signed binding manifest next to a saved ``tfplan`` that
             records the environment, commit SHA, mode (apply|destroy), the
             GitHub run id/attempt and a UTC timestamp, then HMAC it with the
             per-environment ``PLAN_ENCRYPTION_KEY`` so a tampered or
             mismatched plan is rejected at apply time.

``seal``     Encrypt the saved ``tfplan`` + manifest into a single artifact
             using AES-GCM derived from ``PLAN_ENCRYPTION_KEY`` so the plan is
             encrypted at rest while it crosses jobs.

``open``     Decrypt a sealed artifact, verify the HMAC binding against the
             *expected* environment / SHA / mode (supplied by the consuming
             job) and the freshness window, then materialise the plaintext
             ``tfplan`` only when every check passes. A stale, cross-env or
             cross-SHA plan is a hard failure.

``opa``      Convert a saved plan to JSON (caller runs ``terraform show``) and
             evaluate **every** ``deny`` rule in **every** policy package found
             under the policies directory against that exact JSON, failing on
             any decision. Package discovery is dynamic so a newly added
             package is enforced automatically.

The crypto uses only the Python standard library (``hashlib`` /
``hmac``) plus a dependency-free AES-GCM implementation is intentionally *not*
reimplemented here — instead we require ``cryptography`` which is present on
GitHub-hosted runners' Python toolchain via ``pip`` in the workflow. If it is
unavailable the command fails loudly rather than silently downgrading.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

MANIFEST_NAME = "tfplan.binding.json"
SEALED_NAME = "tfplan.sealed"
PLAINTEXT_PLAN = "tfplan"
VALID_MODES = ("apply", "destroy")
# Reject a saved plan older than this many seconds at open time. A plan is
# produced and consumed inside a single workflow run; a generous but finite
# window prevents replaying an old artifact against fresh state.
DEFAULT_MAX_AGE_SECONDS = 6 * 60 * 60  # 6h


# ---------------------------------------------------------------------------
# Key handling
# ---------------------------------------------------------------------------
def _require_key() -> bytes:
    raw = os.environ.get("PLAN_ENCRYPTION_KEY", "")
    if not raw:
        _fail(
            "PLAN_ENCRYPTION_KEY is empty — the trusted plan/apply environment "
            "must supply the per-environment plan key."
        )
    # Accept raw text or base64; normalise to a 32-byte key via SHA-256 so any
    # sufficiently random secret works without imposing a length constraint.
    return hashlib.sha256(raw.encode("utf-8")).digest()


def _hmac_key(master: bytes) -> bytes:
    return hmac.new(master, b"tfplan-binding-v1", hashlib.sha256).digest()


def _aead_key(master: bytes) -> bytes:
    return hmac.new(master, b"tfplan-aead-v1", hashlib.sha256).digest()


# ---------------------------------------------------------------------------
# Binding manifest
# ---------------------------------------------------------------------------
def _manifest_signature(master: bytes, payload: dict) -> str:
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hmac.new(_hmac_key(master), canonical, hashlib.sha256).hexdigest()


def _build_payload(args: argparse.Namespace, plan_digest: str) -> dict:
    return {
        "schema": "tfplan-binding/1",
        "environment": args.environment,
        "sha": args.sha,
        "mode": args.mode,
        "run_id": args.run_id,
        "run_attempt": args.run_attempt,
        "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "plan_sha256": plan_digest,
    }


def _digest_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def cmd_bind(args: argparse.Namespace) -> int:
    if args.mode not in VALID_MODES:
        _fail(f"mode must be one of {VALID_MODES}, got {args.mode!r}")
    plan = Path(args.plan)
    if not plan.is_file():
        _fail(f"saved plan not found: {plan}")
    master = _require_key()
    payload = _build_payload(args, _digest_file(plan))
    signature = _manifest_signature(master, payload)
    manifest = {"payload": payload, "signature": signature}
    out = Path(args.manifest)
    out.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"✓ Bound plan '{plan}' → env={payload['environment']} "
          f"sha={payload['sha'][:7]} mode={payload['mode']} at {payload['created_at']}")
    return 0


# ---------------------------------------------------------------------------
# Sealing (encrypt at rest)
# ---------------------------------------------------------------------------
def _load_aesgcm():
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM  # noqa: WPS433
    except ImportError:
        _fail(
            "python 'cryptography' package is required for seal/open — install it "
            "in the workflow (pip install cryptography) before sealing the plan."
        )
    return AESGCM


def cmd_seal(args: argparse.Namespace) -> int:
    plan = Path(args.plan)
    manifest = Path(args.manifest)
    for p in (plan, manifest):
        if not p.is_file():
            _fail(f"required file not found: {p}")
    master = _require_key()
    AESGCM = _load_aesgcm()
    aead = AESGCM(_aead_key(master))
    nonce = os.urandom(12)
    bundle = {
        "manifest": base64.b64encode(manifest.read_bytes()).decode("ascii"),
        "plan": base64.b64encode(plan.read_bytes()).decode("ascii"),
    }
    plaintext = json.dumps(bundle, separators=(",", ":")).encode("utf-8")
    # Authenticate the environment as associated data so a sealed blob cannot be
    # replayed into a different environment's job even if the key were shared.
    aad = args.environment.encode("utf-8")
    ciphertext = aead.encrypt(nonce, plaintext, aad)
    sealed = {
        "schema": "tfplan-sealed/1",
        "environment": args.environment,
        "nonce": base64.b64encode(nonce).decode("ascii"),
        "ciphertext": base64.b64encode(ciphertext).decode("ascii"),
    }
    Path(args.out).write_text(json.dumps(sealed) + "\n", encoding="utf-8")
    print(f"✓ Sealed plan for env={args.environment} → {args.out}")
    return 0


def cmd_open(args: argparse.Namespace) -> int:
    if args.mode not in VALID_MODES:
        _fail(f"mode must be one of {VALID_MODES}, got {args.mode!r}")
    sealed_path = Path(args.sealed)
    if not sealed_path.is_file():
        _fail(f"sealed artifact not found: {sealed_path}")
    master = _require_key()
    AESGCM = _load_aesgcm()

    sealed = json.loads(sealed_path.read_text(encoding="utf-8"))
    if sealed.get("schema") != "tfplan-sealed/1":
        _fail("sealed artifact schema mismatch — refusing to open")
    if sealed.get("environment") != args.environment:
        _fail(
            f"sealed artifact env '{sealed.get('environment')}' != expected "
            f"'{args.environment}' — refusing cross-environment plan"
        )

    aead = AESGCM(_aead_key(master))
    nonce = base64.b64decode(sealed["nonce"])
    ciphertext = base64.b64decode(sealed["ciphertext"])
    aad = args.environment.encode("utf-8")
    try:
        plaintext = aead.decrypt(nonce, ciphertext, aad)
    except Exception:  # noqa: BLE001 — any auth failure is fatal
        _fail("sealed artifact failed authenticated decryption — tampered or wrong key")

    bundle = json.loads(plaintext.decode("utf-8"))
    manifest = json.loads(base64.b64decode(bundle["manifest"]).decode("utf-8"))
    plan_bytes = base64.b64decode(bundle["plan"])

    payload = manifest.get("payload", {})
    signature = manifest.get("signature", "")
    expected_sig = _manifest_signature(master, payload)
    if not hmac.compare_digest(signature, expected_sig):
        _fail("binding manifest HMAC invalid — plan binding was tampered with")

    _verify_binding(payload, plan_bytes, args)

    out_plan = Path(args.out)
    out_plan.write_bytes(plan_bytes)
    print(
        f"✓ Opened verified plan env={payload['environment']} "
        f"sha={payload['sha'][:7]} mode={payload['mode']} → {out_plan}"
    )
    return 0


def _verify_binding(payload: dict, plan_bytes: bytes, args: argparse.Namespace) -> None:
    if payload.get("environment") != args.environment:
        _fail(f"plan env '{payload.get('environment')}' != expected '{args.environment}'")
    if payload.get("sha") != args.sha:
        _fail(f"plan SHA '{payload.get('sha')}' != expected '{args.sha}' — stale/foreign plan")
    if payload.get("mode") != args.mode:
        _fail(f"plan mode '{payload.get('mode')}' != expected '{args.mode}'")
    actual_digest = hashlib.sha256(plan_bytes).hexdigest()
    if payload.get("plan_sha256") != actual_digest:
        _fail("plan digest mismatch — saved plan bytes do not match binding")

    created = payload.get("created_at", "")
    try:
        created_dt = datetime.strptime(created, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        _fail(f"binding created_at is unparseable: {created!r}")
    age = (datetime.now(timezone.utc) - created_dt).total_seconds()
    if age < 0:
        _fail("binding created_at is in the future — rejecting")
    if age > args.max_age_seconds:
        _fail(
            f"saved plan is {int(age)}s old (limit {args.max_age_seconds}s) — "
            "refusing to apply a stale plan"
        )


# ---------------------------------------------------------------------------
# OPA evaluation across every policy package
# ---------------------------------------------------------------------------
def _discover_packages(policies_dir: Path) -> list[str]:
    """Return the sorted, de-duplicated list of Rego ``package`` names."""
    packages: set[str] = set()
    for rego in sorted(policies_dir.rglob("*.rego")):
        for line in rego.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if stripped.startswith("package "):
                packages.add(stripped[len("package "):].strip())
                break
    return sorted(packages)


def cmd_opa(args: argparse.Namespace) -> int:
    policies_dir = Path(args.policies)
    if not policies_dir.is_dir():
        _fail(f"policies directory not found: {policies_dir}")
    plan_json = Path(args.plan_json)
    if not plan_json.is_file():
        _fail(f"plan JSON not found: {plan_json} (run 'terraform show -json tfplan' first)")

    packages = _discover_packages(policies_dir)
    if not packages:
        _fail(f"no Rego packages discovered under {policies_dir}")

    print(f"Evaluating {len(packages)} policy package(s) against {plan_json}:")
    violations: list[str] = []
    for pkg in packages:
        query = f"data.{pkg}.deny"
        proc = subprocess.run(  # noqa: S603 — fixed binary, no shell, args are discovered pkg names
            [
                args.opa_bin,
                "eval",
                "--format=json",
                "--data",
                str(policies_dir),
                "--input",
                str(plan_json),
                query,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode != 0:
            _fail(f"opa eval failed for package '{pkg}':\n{proc.stderr.strip()}")
        decisions = _extract_denies(proc.stdout)
        if decisions:
            print(f"  ✗ {pkg}: {len(decisions)} violation(s)")
            violations.extend(f"[{pkg}] {d}" for d in decisions)
        else:
            print(f"  ✓ {pkg}: pass")

    if violations:
        print("\nPolicy violations:", file=sys.stderr)
        for v in violations:
            print(f"  - {v}", file=sys.stderr)
        _fail(f"{len(violations)} OPA policy violation(s) across {len(packages)} package(s)")

    print(f"\n✓ All {len(packages)} policy package(s) passed against exact plan JSON")
    return 0


def _extract_denies(opa_stdout: str) -> list[str]:
    try:
        data = json.loads(opa_stdout)
    except json.JSONDecodeError:
        return []
    results = data.get("result", [])
    out: list[str] = []
    for res in results:
        for expr in res.get("expressions", []):
            value = expr.get("value")
            if isinstance(value, list):
                out.extend(str(v) for v in value)
            elif isinstance(value, dict):
                out.extend(str(v) for v in value.values())
            elif value:
                out.append(str(value))
    return out


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def _fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    bind = sub.add_parser("bind", help="write a signed binding manifest for a saved plan")
    bind.add_argument("--plan", default=PLAINTEXT_PLAN)
    bind.add_argument("--manifest", default=MANIFEST_NAME)
    bind.add_argument("--environment", required=True)
    bind.add_argument("--sha", required=True)
    bind.add_argument("--mode", required=True, choices=VALID_MODES)
    bind.add_argument("--run-id", required=True, dest="run_id")
    bind.add_argument("--run-attempt", required=True, dest="run_attempt")
    bind.set_defaults(func=cmd_bind)

    seal = sub.add_parser("seal", help="encrypt plan + manifest into a sealed artifact")
    seal.add_argument("--plan", default=PLAINTEXT_PLAN)
    seal.add_argument("--manifest", default=MANIFEST_NAME)
    seal.add_argument("--environment", required=True)
    seal.add_argument("--out", default=SEALED_NAME)
    seal.set_defaults(func=cmd_seal)

    opn = sub.add_parser("open", help="verify + decrypt a sealed artifact to a plaintext plan")
    opn.add_argument("--sealed", default=SEALED_NAME)
    opn.add_argument("--out", default=PLAINTEXT_PLAN)
    opn.add_argument("--environment", required=True)
    opn.add_argument("--sha", required=True)
    opn.add_argument("--mode", required=True, choices=VALID_MODES)
    opn.add_argument("--max-age-seconds", type=int, default=DEFAULT_MAX_AGE_SECONDS,
                     dest="max_age_seconds")
    opn.set_defaults(func=cmd_open)

    opa = sub.add_parser("opa", help="evaluate every policy package against a plan JSON")
    opa.add_argument("--policies", required=True)
    opa.add_argument("--plan-json", required=True, dest="plan_json")
    opa.add_argument("--opa-bin", default="opa", dest="opa_bin")
    opa.set_defaults(func=cmd_opa)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
