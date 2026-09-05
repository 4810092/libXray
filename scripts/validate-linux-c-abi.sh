#!/usr/bin/env bash

# Build and inspect the Linux amd64 C ABI without modifying the source tree.
# The digest pins the public Go image's linux/amd64 manifest, while the source
# is mounted read-only and all output/cache state is confined to --rm Docker.
set -euo pipefail

readonly GO_IMAGE='golang:1.26.3@sha256:3bf5b04541eb4a37fe62aa1bc9c98a1dec09db9d2e79c1d2eb54e3c9d08dbca9'
readonly PLATFORM='linux/amd64'

if [[ "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
Usage: scripts/validate-linux-c-abi.sh

Pulls the pinned public Go linux/amd64 image through an empty temporary Docker
configuration, mounts this source tree read-only, builds cgo_bridge with
`-mod=readonly -trimpath -buildvcs=false -ldflags=-buildid= -buildmode=c-shared`,
and checks the CGoFree header
and exported ELF symbol. No source or artifact files are retained.
USAGE
  exit 0
fi

repo_root="$(git rev-parse --show-toplevel)"
command -v docker >/dev/null 2>&1 || {
  echo "Linux C ABI validation requires Docker Desktop" >&2
  exit 1
}
docker version --format '{{.Server.Version}}' >/dev/null 2>&1 || {
  echo "Linux C ABI validation requires a reachable Docker daemon" >&2
  exit 1
}

umask 077
docker_config="$(mktemp -d "${TMPDIR:-/tmp}/libxray-docker-config.XXXXXX")"
output_dir="$(mktemp -d "${TMPDIR:-/tmp}/libxray-linux-c-abi.XXXXXX")"

cleanup() {
  local cleanup_failed=0
  set +e
  rm -f "$output_dir/libXray.so" "$output_dir/libXray.h" || cleanup_failed=1
  rmdir "$output_dir" || cleanup_failed=1
  rmdir "$docker_config" || cleanup_failed=1
  if [[ "$cleanup_failed" -ne 0 ]]; then
    echo "Linux C ABI validation cleanup failed; refusing success" >&2
    return 1
  fi
}

on_exit() {
  local status=$?
  trap - EXIT
  cleanup || exit 1
  exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT TERM

# --config deliberately points to an empty directory: Docker cannot read the
# user's credential helpers, registry auth, proxies, or per-user settings.
docker --config "$docker_config" pull --platform "$PLATFORM" "$GO_IMAGE" >/dev/null
docker --config "$docker_config" image inspect "$GO_IMAGE" >/dev/null

docker --config "$docker_config" run --rm --platform "$PLATFORM" --pull=never \
  --mount "type=bind,src=$repo_root,dst=/src,readonly" \
  --mount "type=bind,src=$output_dir,dst=/out" \
  --workdir /src \
  "$GO_IMAGE" \
  /bin/sh -ec '
    export CGO_ENABLED=1
    go build -mod=readonly -trimpath -buildvcs=false -ldflags=-buildid= -buildmode=c-shared -o /out/libXray.so ./cgo_bridge
    test -s /out/libXray.so
    test -s /out/libXray.h
    grep -Eq "void CGoFree\\(" /out/libXray.h
    nm -D --defined-only /out/libXray.so | grep -Eq "[[:space:]]CGoFree$"
  '

echo "Linux amd64 C ABI validation passed with pinned $GO_IMAGE"
