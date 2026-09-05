#!/usr/bin/env bash

# Opt in to the tracked hook directory. This changes only repository-local
# configuration and never creates an unversioned hook in .git.
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
Usage: scripts/install-pre-push-hook.sh

Configures this checkout to use the tracked .githooks/pre-push launcher.
USAGE
  exit 0
fi

repo_root="$(git rev-parse --show-toplevel)"
hook_path="$repo_root/.githooks/pre-push"
[[ -x "$hook_path" ]] || {
  echo "tracked pre-push hook is missing or not executable: $hook_path" >&2
  exit 1
}

git -C "$repo_root" config --local core.hooksPath .githooks
[[ "$(git -C "$repo_root" config --local --get core.hooksPath)" == ".githooks" ]] || {
  echo "failed to configure tracked hooks path" >&2
  exit 1
}
echo "configured tracked libXray pre-push hook: $hook_path"
