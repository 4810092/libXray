#!/usr/bin/env bash

# Check only the tools used by the deterministic, source-only pre-push gate.
# Platform artifact builds deliberately have separate prerequisites and are not
# part of this hook.
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
Usage: scripts/check-local-pre-push-prereqs.sh

Checks the exact Go toolchain declared in go.mod plus git and actionlint.
It performs no network access and does not modify the working tree.
USAGE
  exit 0
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_command git
require_command go
require_command actionlint

expected_go="$(awk '$1 == "go" { print $2; exit }' go.mod)"
if [[ ! "$expected_go" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "go.mod must declare an exact Go patch version; found: ${expected_go:-missing}" >&2
  exit 1
fi

actual_go="$(go env GOVERSION)"
if [[ "$actual_go" != "go$expected_go" ]]; then
  echo "Go toolchain mismatch: required go$expected_go, found $actual_go" >&2
  exit 1
fi

echo "local pre-push prerequisites satisfied: $actual_go, $(actionlint -version | head -n 1)"
