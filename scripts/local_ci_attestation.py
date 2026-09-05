#!/usr/bin/env python3
"""Strict helpers for signed exact-SHA local-CI Git-note attestations."""
from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile


SHA1 = re.compile(r"^[0-9a-f]{40}$")
IDENTITY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.@-]{0,127}$")
EMPTY_TREE_SHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
NOTE_REF = "refs/notes/ekhovpn-local-ci/v1"
NAMESPACE = "ekhovpn-local-ci-attestation-v1"
GATE_ID = "libxray-local-pre-push"
GATE_VERSION = 1
MAX_NOTE_BYTES = 16 * 1024
MAX_SIGNERS_BYTES = 64 * 1024
MANIFEST_PATHS = (
    ".githooks/pre-push",
    "scripts/check-local-pre-push-prereqs.sh",
    "scripts/install-pre-push-hook.sh",
    "scripts/local-pre-push-ci.sh",
    "scripts/local_ci_attestation.py",
    "scripts/write_local_ci_attestation.py",
    "scripts/verify_local_ci_attestation.py",
    "scripts/test-local-pre-push-ci.sh",
    ".github/actions/verify-local-ci-attestation/action.yml",
)


class AttestationError(RuntimeError):
    """The signed local-CI evidence is missing, malformed, or untrusted."""


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii")


def _strict_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise AttestationError("duplicate attestation JSON key")
        result[key] = value
    return result


def _exact(value: object, keys: set[str], label: str) -> dict[str, object]:
    if type(value) is not dict or set(value) != keys:
        raise AttestationError(f"attestation {label} is invalid")
    return value


def _sha(value: object, label: str) -> str:
    if type(value) is not str or not SHA1.fullmatch(value):
        raise AttestationError(f"attestation {label} is invalid")
    return value


def git(repo: Path, *args: str) -> str:
    try:
        return subprocess.check_output(["git", "-C", str(repo), *args], text=True, stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        raise AttestationError("attestation Git object is unavailable") from exc


def require_commit_range(repo: Path, commit: str, base: str) -> None:
    _sha(commit, "commit")
    _sha(base, "base")
    git(repo, "cat-file", "-e", f"{commit}^{{commit}}")
    if base == EMPTY_TREE_SHA:
        if git(repo, "hash-object", "-t", "tree", "/dev/null") != EMPTY_TREE_SHA:
            raise AttestationError("attestation empty-tree base is unavailable")
        return
    git(repo, "cat-file", "-e", f"{base}^{{commit}}")
    try:
        subprocess.run(["git", "-C", str(repo), "merge-base", "--is-ancestor", base, commit], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.CalledProcessError) as exc:
        raise AttestationError("attestation base is not an ancestor") from exc


def manifest_digest(repo: Path, commit: str) -> str:
    entries: list[dict[str, str]] = []
    for path in MANIFEST_PATHS:
        blob = git(repo, "rev-parse", f"{commit}:{path}")
        if not SHA1.fullmatch(blob):
            raise AttestationError("attestation gate manifest is invalid")
        entries.append({"blob_sha1": blob, "path": path})
    return hashlib.sha256(canonical(entries)).hexdigest()


def build_payload(repo: Path, commit: str, base: str) -> dict[str, object]:
    require_commit_range(repo, commit, base)
    tree = git(repo, "rev-parse", f"{commit}^{{tree}}")
    _sha(tree, "tree")
    return {"base": base, "commit": commit, "gate_id": GATE_ID,
            "gate_manifest_sha256": manifest_digest(repo, commit), "gate_version": GATE_VERSION,
            "result": "PASS", "schema": 1, "tree": tree}


def _private_regular(path: Path, max_bytes: int, label: str) -> bytes:
    try:
        before = path.lstat()
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as exc:
        raise AttestationError(f"attestation {label} is unavailable") from exc
    try:
        opened = os.fstat(fd)
        if (path.is_symlink() or not stat.S_ISREG(opened.st_mode)
                or (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino)
                or opened.st_uid != os.geteuid() or stat.S_IMODE(opened.st_mode) != 0o600
                or opened.st_nlink != 1 or not 0 < opened.st_size <= max_bytes):
            raise AttestationError(f"attestation {label} is unsafe")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(fd, min(65536, max_bytes + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > max_bytes:
                raise AttestationError(f"attestation {label} is unsafe")
        return b"".join(chunks)
    except OSError as exc:
        raise AttestationError(f"attestation {label} is unavailable") from exc
    finally:
        os.close(fd)


def _sign(payload: dict[str, object], key: Path) -> bytes:
    if not key.is_absolute():
        raise AttestationError("attestation key path must be absolute")
    _private_regular(key, 64 * 1024, "signing key")
    with tempfile.TemporaryDirectory(prefix="libxray-local-ci-attestation-") as temp:
        data = Path(temp) / "payload"
        data.write_bytes(canonical(payload))
        try:
            subprocess.run(["ssh-keygen", "-Y", "sign", "-f", str(key), "-n", NAMESPACE, str(data)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return Path(str(data) + ".sig").read_bytes()
        except (OSError, subprocess.CalledProcessError) as exc:
            raise AttestationError("attestation signing failed") from exc


def write_note(repo: Path, commit: str, base: str, key: Path, identity: str) -> bytes:
    if not IDENTITY.fullmatch(identity):
        raise AttestationError("attestation identity is invalid")
    payload = build_payload(repo, commit, base)
    return canonical({"attestation_schema": 1, "payload": payload, "signature": {
        "armored_base64": base64.b64encode(_sign(payload, key)).decode("ascii"),
        "identity": identity, "namespace": NAMESPACE}})


def verify_note(repo: Path, raw: bytes, expected_commit: str, allowed_signers: Path, identity: str) -> None:
    if not IDENTITY.fullmatch(identity) or not raw or len(raw) > MAX_NOTE_BYTES:
        raise AttestationError("attestation note is invalid")
    try:
        note = json.loads(raw.decode("utf-8"), object_pairs_hook=_strict_object)
    except (UnicodeDecodeError, json.JSONDecodeError, AttestationError) as exc:
        raise AttestationError("attestation note is invalid") from exc
    outer = _exact(note, {"attestation_schema", "payload", "signature"}, "note")
    payload = _exact(outer["payload"], {"base", "commit", "gate_id", "gate_manifest_sha256", "gate_version", "result", "schema", "tree"}, "payload")
    commit = _sha(payload["commit"], "payload commit")
    base = _sha(payload["base"], "payload base")
    if (outer["attestation_schema"] != 1 or commit != expected_commit or payload["schema"] != 1
            or payload["gate_id"] != GATE_ID or payload["gate_version"] != GATE_VERSION or payload["result"] != "PASS"):
        raise AttestationError("attestation payload is invalid")
    require_commit_range(repo, commit, base)
    if payload["tree"] != git(repo, "rev-parse", f"{commit}^{{tree}}") or payload["gate_manifest_sha256"] != manifest_digest(repo, commit):
        raise AttestationError("attestation payload does not match commit")
    signature = _exact(outer["signature"], {"armored_base64", "identity", "namespace"}, "signature")
    if signature["identity"] != identity or signature["namespace"] != NAMESPACE or type(signature["armored_base64"]) is not str:
        raise AttestationError("attestation signature is invalid")
    try:
        armored = base64.b64decode(signature["armored_base64"], validate=True)
    except (TypeError, ValueError) as exc:
        raise AttestationError("attestation signature is invalid") from exc
    if not armored or len(armored) > MAX_NOTE_BYTES:
        raise AttestationError("attestation signature is invalid")
    _private_regular(allowed_signers, MAX_SIGNERS_BYTES, "allowed signers")
    with tempfile.TemporaryDirectory(prefix="libxray-local-ci-attestation-") as temp:
        sig = Path(temp) / "payload.sig"
        sig.write_bytes(armored)
        try:
            subprocess.run(["ssh-keygen", "-Y", "verify", "-f", str(allowed_signers), "-I", identity,
                            "-n", NAMESPACE, "-s", str(sig)], input=canonical(payload), check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except (OSError, subprocess.CalledProcessError) as exc:
            raise AttestationError("attestation signature verification failed") from exc
