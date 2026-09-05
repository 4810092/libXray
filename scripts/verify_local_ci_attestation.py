#!/usr/bin/env python3
"""Verify an exact-SHA signed local-CI note in a provider workflow."""
import argparse
from pathlib import Path
import sys

import local_ci_attestation as attestation


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--note", required=True, type=Path)
    parser.add_argument("--allowed-signers", required=True, type=Path)
    parser.add_argument("--expected-sha", required=True)
    parser.add_argument("--identity", required=True)
    args = parser.parse_args()
    try:
        raw = attestation._private_regular(args.note, attestation.MAX_NOTE_BYTES, "note")
        attestation.verify_note(args.repo.resolve(), raw, args.expected_sha, args.allowed_signers, args.identity)
        print(f"local-ci attestation: PASS sha={args.expected_sha}")
        return 0
    except attestation.AttestationError as exc:
        print(f"local-ci attestation: FAIL {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
