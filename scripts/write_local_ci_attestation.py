#!/usr/bin/env python3
"""Write a canonical SSHSIG local-CI attestation after the full local gate."""
import argparse
import os
from pathlib import Path
import stat
import sys

import local_ci_attestation as attestation


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--key", required=True, type=Path)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        if not args.output.is_absolute() or args.output.exists() or args.output.is_symlink():
            raise attestation.AttestationError("attestation output is unsafe")
        payload = attestation.write_note(args.repo.resolve(), args.commit, args.base, args.key, args.identity)
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise attestation.AttestationError("attestation output is unsafe")
            view = memoryview(payload)
            while view:
                view = view[os.write(fd, view) :]
            os.fsync(fd)
        finally:
            os.close(fd)
        return 0
    except attestation.AttestationError as exc:
        print(f"local-ci attestation: FAIL {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
