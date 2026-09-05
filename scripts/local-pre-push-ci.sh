#!/usr/bin/env bash

# Validate the exact commit Git is about to push. Validation always happens in
# a detached worktree and starts from an intentionally tiny environment.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/local-pre-push-ci.sh --pre-push <remote-name> <remote-url>

Read standard pre-push ref updates from stdin. Only one non-deletion branch
update is accepted. The gate validates its exact local commit in a detached
temporary worktree and fails closed for unsupported refs, divergent remote
bases, missing objects, concurrent runs, or toolchain mismatches.  After a
PASS it signs that exact SHA and publishes a Git note before Git pushes the
branch, so provider-side mutation workflows can independently verify it.
USAGE
}

fail() {
  echo "local pre-push CI: $*" >&2
  exit 1
}

validate_absolute_path() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^/[^[:cntrl:]]*$ ]] || fail "unsafe $name"
}

sanitize_environment() {
  [[ "${LIBXRAY_LOCAL_CI_SANITIZED:-}" != "1" ]] || return 0

  local safe_home="${HOME:-}"
  local safe_path="${PATH:-}"
  local safe_tmpdir="${TMPDIR:-/tmp}"
  local safe_lang="${LANG:-C}"
  local safe_user="${USER:-unknown}"
  local safe_shell="${SHELL:-/bin/bash}"
  local path_part

  validate_absolute_path HOME "$safe_home"
  validate_absolute_path TMPDIR "$safe_tmpdir"
  validate_absolute_path SHELL "$safe_shell"
  [[ "$safe_lang" =~ ^[A-Za-z0-9_.@-]+$ ]] || fail "unsafe LANG"
  [[ "$safe_user" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "unsafe USER"
  [[ -n "$safe_path" ]] || fail "empty PATH"
  local IFS=:
  for path_part in $safe_path; do
    validate_absolute_path PATH "$path_part"
  done

  exec /usr/bin/env -i \
    "HOME=$safe_home" \
    "PATH=$safe_path" \
    "TMPDIR=$safe_tmpdir" \
    "LANG=$safe_lang" \
    "USER=$safe_user" \
    "SHELL=$safe_shell" \
    "GIT_PAGER=cat" \
    "PAGER=cat" \
    "GIT_TERMINAL_PROMPT=0" \
    "LIBXRAY_LOCAL_CI_SANITIZED=1" \
    /bin/bash "$0" "$@"
}

if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

sanitize_environment "$@"

if [[ "${1:-}" == "--sanitized-env-check" && "$#" -eq 1 ]]; then
  /usr/bin/env | LC_ALL=C sort
  exit 0
fi
cleanup_self_test=0
if [[ "${1:-}" == "--cleanup-self-test" && "$#" -eq 1 ]]; then
  cleanup_self_test=1
elif [[ "${1:-}" != "--pre-push" || "$#" -ne 3 ]]; then
  usage >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"
git_common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)"
cd "$repo_root"

updates_file="$(mktemp "${TMPDIR}/libxray-pre-push-updates.XXXXXX")"
scratch_root=""
worktree=""
attestation_note=""
lock_dir="$git_common_dir/libxray-local-pre-push.lock"
lock_owned=0
worktree_created=0

cleanup() {
  local cleanup_failed=0
  set +e
  if [[ "$worktree_created" -eq 1 ]]; then
    if git -C "$repo_root" worktree remove --force "$worktree" >/dev/null 2>&1; then
      worktree_created=0
    else
      cleanup_failed=1
    fi
  fi
  if [[ -n "$attestation_note" ]]; then
    if [[ "$attestation_note" == "$scratch_root/local-ci-attestation.json" ]] && rm -f -- "$attestation_note"; then
      attestation_note=""
    else
      cleanup_failed=1
    fi
  fi
  if [[ -n "$scratch_root" ]]; then
    if rmdir "$scratch_root" >/dev/null 2>&1; then
      scratch_root=""
    else
      cleanup_failed=1
    fi
  fi
  if [[ -n "$updates_file" ]]; then
    if rm -f "$updates_file" >/dev/null 2>&1; then
      updates_file=""
    else
      cleanup_failed=1
    fi
  fi
  if [[ "$lock_owned" -eq 1 ]]; then
    if [[ "$(cat "$lock_dir/pid" 2>/dev/null)" == "$$" ]] \
      && rm -f "$lock_dir/pid" >/dev/null 2>&1 \
      && rmdir "$lock_dir" >/dev/null 2>&1; then
      lock_owned=0
    else
      cleanup_failed=1
    fi
  fi
  if [[ "$cleanup_failed" -ne 0 ]]; then
    echo "local pre-push CI: cleanup failed; refusing success" >&2
    return 1
  fi
}

if [[ "$cleanup_self_test" -eq 1 ]]; then
  scratch_root="$(mktemp -d "${TMPDIR}/libxray-pre-push-cleanup.XXXXXX")"
  attestation_note="$scratch_root/local-ci-attestation.json"
  printf '%s\n' regression >"$attestation_note"
  test_root="$scratch_root"
  cleanup
  [[ -z "$scratch_root" && -z "$attestation_note" && -z "$updates_file" && ! -e "$test_root" ]] || {
    echo "local pre-push CI: attestation cleanup regression" >&2
    exit 1
  }
  exit 0
fi

on_exit() {
  local status=$?
  trap - EXIT
  cleanup || exit 1
  exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT TERM

cat >"$updates_file"
update_count="$(awk 'NF { count += 1 } END { print count + 0 }' "$updates_file")"
[[ "$update_count" == "1" ]] || fail "accepts exactly one branch update per push; found $update_count"

read -r local_ref local_sha remote_ref remote_sha extra <"$updates_file"
[[ -z "${extra:-}" ]] || fail "malformed pre-push update"
zero_sha='0000000000000000000000000000000000000000'
[[ "$local_ref" =~ ^refs/heads/ && "$remote_ref" =~ ^refs/heads/ ]] || fail "accepts branch refs only"
[[ "$local_sha" != "$zero_sha" ]] || fail "does not allow branch deletions"
[[ "$local_sha" =~ ^[0-9a-f]{40}$ ]] || fail "invalid local commit id"
git cat-file -e "${local_sha}^{commit}" || fail "cannot resolve exact pushed commit: $local_sha"

if [[ "$remote_sha" == "$zero_sha" ]]; then
  diff_base="$(git hash-object -t tree /dev/null)"
else
  [[ "$remote_sha" =~ ^[0-9a-f]{40}$ ]] || fail "invalid remote base commit id"
  git cat-file -e "${remote_sha}^{commit}" || fail "cannot resolve remote base commit: $remote_sha"
  git merge-base --is-ancestor "$remote_sha" "$local_sha" || fail "remote base is not an ancestor of pushed commit"
  diff_base="$remote_sha"
fi

acquire_lock() {
  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" >"$lock_dir/pid"
    lock_owned=1
    return
  fi

  local stale_pid
  stale_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
  [[ "$stale_pid" =~ ^[1-9][0-9]*$ ]] || fail "local CI lock exists without a recoverable PID: $lock_dir"
  kill -0 "$stale_pid" 2>/dev/null && fail "local CI already running (PID $stale_pid)"
  rm -f "$lock_dir/pid" || fail "cannot recover stale local CI lock"
  rmdir "$lock_dir" || fail "cannot recover stale local CI lock"
  mkdir "$lock_dir" || fail "cannot acquire local CI lock"
  printf '%s\n' "$$" >"$lock_dir/pid"
  lock_owned=1
}

assert_exact_clean_worktree() {
  [[ "$(git -C "$worktree" rev-parse HEAD)" == "$local_sha" ]] || fail "temporary worktree HEAD changed"
  [[ -z "$(git -C "$worktree" status --porcelain=v1 --untracked-files=all)" ]] || fail "temporary worktree is not clean"
}

acquire_lock
scratch_root="$(mktemp -d "${TMPDIR}/libxray-pre-push.XXXXXX")"
worktree="$scratch_root/repo"
git -C "$repo_root" worktree add --detach "$worktree" "$local_sha" >/dev/null
worktree_created=1

assert_exact_clean_worktree
"$worktree/scripts/check-local-pre-push-prereqs.sh"
git -C "$worktree" diff --check "$diff_base" "$local_sha"
(
  cd "$worktree"
  actionlint
  go test ./... -count=1 -timeout 15m
  go test -race ./... -count=1 -timeout 15m
  go vet ./...
)
"$worktree/scripts/validate-linux-c-abi.sh"
assert_exact_clean_worktree

attestation_key="$(git -C "$repo_root" config --file "$git_common_dir/config" --get libxray.localCiAttestationKey || true)"
attestation_identity="$(git -C "$repo_root" config --file "$git_common_dir/config" --get libxray.localCiAttestationIdentity || true)"
[[ "$attestation_key" == /* && -n "$attestation_identity" ]] || fail "run scripts/install-pre-push-hook.sh with an attestation key first"
attestation_note_ref="refs/notes/ekhovpn-local-ci/v1"
attestation_note="$scratch_root/local-ci-attestation.json"
python3 "$worktree/scripts/write_local_ci_attestation.py" \
  --repo "$worktree" \
  --commit "$local_sha" \
  --base "$diff_base" \
  --key "$attestation_key" \
  --identity "$attestation_identity" \
  --output "$attestation_note"
if git -C "$repo_root" notes --ref "$attestation_note_ref" show "$local_sha" >/dev/null 2>&1; then
  fail "refusing to replace an existing local-CI attestation"
fi
git -C "$repo_root" notes --ref "$attestation_note_ref" add -F "$attestation_note" "$local_sha"
if ! git -C "$repo_root" push --no-verify "$2" "$attestation_note_ref:$attestation_note_ref"; then
  git -C "$repo_root" notes --ref "$attestation_note_ref" remove "$local_sha" >/dev/null 2>&1 || true
  fail "attestation note publication failed"
fi

echo "local pre-push CI passed for $local_ref at $local_sha"
