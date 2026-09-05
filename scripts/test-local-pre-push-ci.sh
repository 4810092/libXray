#!/usr/bin/env bash

# Structural test: it deliberately avoids a platform build and a real push.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

for script in \
  scripts/check-local-pre-push-prereqs.sh \
  scripts/local-pre-push-ci.sh \
  scripts/install-pre-push-hook.sh; do
  test -x "$script" || { echo "not executable: $script" >&2; exit 1; }
  bash -n "$script"
  "$script" --help >/dev/null
done
test -x .githooks/pre-push || { echo "not executable: .githooks/pre-push" >&2; exit 1; }
bash -n .githooks/pre-push

if printf '%s\n' \
  'refs/tags/v26.7.11 1111111111111111111111111111111111111111 refs/tags/v26.7.11 0000000000000000000000000000000000000000' \
  | scripts/local-pre-push-ci.sh --pre-push origin https://example.invalid/libXray.git >/dev/null 2>&1; then
  echo "pre-push driver accepted a non-branch update" >&2
  exit 1
fi

head_sha="$(git rev-parse HEAD)"
parent_sha="$(git rev-parse HEAD^)"
if printf 'refs/heads/main %s refs/heads/main %s\n' "$parent_sha" "$head_sha" \
  | scripts/local-pre-push-ci.sh --pre-push origin https://example.invalid/libXray.git >/dev/null 2>&1; then
  echo "pre-push driver accepted a remote base that is not an ancestor" >&2
  exit 1
fi

sanitized_env="$(AWS_ACCESS_KEY_ID=forbidden \
  APP_STORE_CONNECT_API_KEY=forbidden \
  FASTLANE_PASSWORD=forbidden \
  GH_TOKEN=forbidden \
  HTTPS_PROXY=https://forbidden \
  scripts/local-pre-push-ci.sh --sanitized-env-check)"
if printf '%s\n' "$sanitized_env" | grep -Eqi '(AWS|STORE|SIGN|PROXY|TOKEN|PASSWORD|SECRET)'; then
  echo "sanitized runner retained a forbidden ambient environment variable" >&2
  exit 1
fi

python3 - <<'PY'
from pathlib import Path

for path in Path(".github/workflows").glob("*.yml"):
    text = path.read_text(encoding="utf-8")
    if "workflow_dispatch:" not in text:
        raise SystemExit(f"missing manual trigger: {path}")
    for forbidden in ("\n  push:", "\n  pull_request:", "\n  schedule:"):
        if forbidden in text:
            raise SystemExit(f"automatic trigger remains in {path}: {forbidden.strip()}")

driver = Path("scripts/local-pre-push-ci.sh").read_text(encoding="utf-8")
for required in (
    "worktree add --detach",
    "git -C \"$worktree\" diff --check",
    "actionlint",
    "go test ./... -count=1 -timeout 15m",
    "go test -race ./... -count=1 -timeout 15m",
    "go vet ./...",
    "git merge-base --is-ancestor",
    "assert_exact_clean_worktree",
):
    if required not in driver:
        raise SystemExit(f"pre-push driver lacks: {required}")

installer = Path("scripts/install-pre-push-hook.sh").read_text(encoding="utf-8")
if "core.hooksPath .githooks" not in installer or ".git/hooks" in installer:
    raise SystemExit("installer does not configure only the tracked hook path")

mirror = Path(".github/workflows/release-go-mirror.yml").read_text(encoding="utf-8")
for required in ('refs/tags/${{ inputs.calver_tag }}', '^{commit}', 'exit 1'):
    if required not in mirror:
        raise SystemExit(f"mirror workflow lacks strict tag validation: {required}")
PY

echo "local pre-push CI structural test passed"
