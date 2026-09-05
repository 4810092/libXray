#!/usr/bin/env bash

# Structural test: it deliberately avoids a platform build and a real push.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

for script in \
  scripts/check-local-pre-push-prereqs.sh \
  scripts/local-pre-push-ci.sh \
  scripts/validate-linux-c-abi.sh \
  scripts/install-pre-push-hook.sh; do
  test -x "$script" || { echo "not executable: $script" >&2; exit 1; }
  bash -n "$script"
  "$script" --help >/dev/null
done
for script in \
  scripts/local_ci_attestation.py \
  scripts/write_local_ci_attestation.py \
  scripts/verify_local_ci_attestation.py; do
  test -x "$script" || { echo "not executable: $script" >&2; exit 1; }
  python3 -m py_compile "$script"
done
test -x .githooks/pre-push || { echo "not executable: .githooks/pre-push" >&2; exit 1; }
bash -n .githooks/pre-push
scripts/local-pre-push-ci.sh --cleanup-self-test

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
    'scripts/validate-linux-c-abi.sh',
    "git merge-base --is-ancestor",
    "assert_exact_clean_worktree",
    "write_local_ci_attestation.py",
    "refs/notes/ekhovpn-local-ci/v1",
    "push --no-verify",
):
    if required not in driver:
        raise SystemExit(f"pre-push driver lacks: {required}")

installer = Path("scripts/install-pre-push-hook.sh").read_text(encoding="utf-8")
if ("core.hooksPath .githooks" not in installer or ".git/hooks" in installer
        or "libxray.localCiAttestationKey" not in installer):
    raise SystemExit("installer does not configure only the tracked hook path")

action = Path(".github/actions/verify-local-ci-attestation/action.yml").read_text(encoding="utf-8")
for required in ("EKHOVPN_LOCAL_CI_ALLOWED_SIGNERS", "refs/notes/ekhovpn-local-ci/v1", "--expected-sha \"$GITHUB_SHA\"", 'test "$GITHUB_REF" = refs/heads/main'):
    if required not in action:
        raise SystemExit(f"attestation action lacks: {required}")

mirror = Path(".github/workflows/release-go-mirror.yml").read_text(encoding="utf-8")
for required in ('refs/tags/${{ inputs.calver_tag }}', '^{commit}', 'exit 1', 'name: release-attestation', 'needs: local_ci_attestation'):
    if required not in mirror:
        raise SystemExit(f"mirror workflow lacks strict tag validation: {required}")

build = Path(".github/workflows/build.yml").read_text(encoding="utf-8")
for required in (
    "actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803",
    "actions/setup-python@ece7cb06caefa5fff74198d8649806c4678c61a1",
    "actions/setup-go@924ae3a1cded613372ab5595356fb5720e22ba16",
    "maxim-lobanov/setup-xcode@ed7a3b1fda3918c0306d1b724322adc0b8cc0a90",
    "actions/setup-java@b6effb05e454b25005698d916606bdc6ffcbf961",
    "android-actions/setup-android@9fc6c4e9069bf8d3d10b2204b1fb8f6ef7065407",
    "nttld/setup-ndk@ed92fe6cadad69be94a966a7ee3271275e62f779",
    "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
    "go-version-file: go.mod",
    "check-latest: false",
):
    if required not in build:
        raise SystemExit(f"build workflow lacks pinned toolchain/action setting: {required}")

linux_abi = Path("scripts/validate-linux-c-abi.sh").read_text(encoding="utf-8")
for required in (
    "golang:1.26.3@sha256:3bf5b04541eb4a37fe62aa1bc9c98a1dec09db9d2e79c1d2eb54e3c9d08dbca9",
    "linux/amd64",
    "--config \"$docker_config\"",
    "readonly",
    "--rm",
    "-mod=readonly -trimpath -buildvcs=false -ldflags=-buildid= -buildmode=c-shared",
    "CGoFree",
):
    if required not in linux_abi:
        raise SystemExit(f"Linux C ABI validator lacks: {required}")
PY

scratch="$(mktemp -d "${TMPDIR:-/tmp}/libxray-attestation-test.XXXXXX")"
cleanup() { rm -rf -- "$scratch"; }
trap cleanup EXIT
key="$scratch/key"
allowed="$scratch/allowed-signers"
note="$scratch/note.json"
ssh-keygen -q -t ed25519 -N '' -f "$key"
chmod 0600 "$key"
printf 'ekhovpn-local-ci %s\n' "$(cat "$key.pub")" > "$allowed"
chmod 0600 "$allowed"
head_sha="$(git rev-parse HEAD)"
base_sha="$(git rev-parse HEAD^)"
python3 scripts/write_local_ci_attestation.py --repo "$repo_root" --commit "$head_sha" --base "$base_sha" --key "$key" --identity ekhovpn-local-ci --output "$note"
python3 scripts/verify_local_ci_attestation.py --repo "$repo_root" --note "$note" --allowed-signers "$allowed" --expected-sha "$head_sha" --identity ekhovpn-local-ci

echo "local pre-push CI structural test passed"
