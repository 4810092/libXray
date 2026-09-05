#!/usr/bin/env bash

# Opt in to the tracked hook directory. This changes only repository-local
# configuration and never creates an unversioned hook in .git.
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
Usage: scripts/install-pre-push-hook.sh --attestation-key /absolute/path/to/private-ed25519-key [--attestation-identity NAME]

Configures this checkout to use the tracked .githooks/pre-push launcher and
stores the absolute path to an existing, private SSH signing key in local Git
configuration. The key is never stored in this repository.
USAGE
  exit 0
fi

attestation_key="${LIBXRAY_LOCAL_CI_ATTESTATION_KEY:-}"
attestation_identity="${LIBXRAY_LOCAL_CI_ATTESTATION_IDENTITY:-ekhovpn-local-ci}"
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --attestation-key)
      [[ "$#" -ge 2 ]] || { echo "missing --attestation-key value" >&2; exit 64; }
      attestation_key="$2"
      shift 2
      ;;
    --attestation-identity)
      [[ "$#" -ge 2 ]] || { echo "missing --attestation-identity value" >&2; exit 64; }
      attestation_identity="$2"
      shift 2
      ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done
[[ "$attestation_key" == /* && -f "$attestation_key" && ! -L "$attestation_key" ]] || {
  echo "an existing absolute local-CI attestation key is required" >&2
  exit 1
}
[[ "$attestation_identity" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]{0,127}$ ]] || {
  echo "invalid local-CI attestation identity" >&2
  exit 1
}
key_owner="$(stat -f '%u' "$attestation_key" 2>/dev/null || stat -c '%u' "$attestation_key")"
key_mode="$(stat -f '%Lp' "$attestation_key" 2>/dev/null || stat -c '%a' "$attestation_key")"
key_links="$(stat -f '%l' "$attestation_key" 2>/dev/null || stat -c '%h' "$attestation_key")"
[[ "$key_owner" == "$(id -u)" && "$key_mode" == "600" && "$key_links" == "1" ]] || {
  echo "local-CI attestation key must be current-user-owned, unlinked mode 0600" >&2
  exit 1
}

repo_root="$(git rev-parse --show-toplevel)"
hook_path="$repo_root/.githooks/pre-push"
[[ -x "$hook_path" ]] || {
  echo "tracked pre-push hook is missing or not executable: $hook_path" >&2
  exit 1
}

git -C "$repo_root" config --local core.hooksPath .githooks
git -C "$repo_root" config --local libxray.localCiAttestationKey "$attestation_key"
git -C "$repo_root" config --local libxray.localCiAttestationIdentity "$attestation_identity"
[[ "$(git -C "$repo_root" config --local --get core.hooksPath)" == ".githooks" ]] || {
  echo "failed to configure tracked hooks path" >&2
  exit 1
}
echo "configured tracked libXray pre-push hook and SSHSIG attestation: $hook_path"
