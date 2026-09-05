# Versioned local pre-push CI

Ordinary source validation runs on the developer machine before a branch push.
The hook validates the exact local commit supplied by Git's pre-push protocol,
not the caller's potentially dirty checkout. It creates a detached temporary
worktree, runs the source-only checks there, then removes it on success,
failure, or interruption.

## Install

The hook is opt-in. The installer sets repository-local `core.hooksPath` to
the tracked `.githooks` directory; it does not write an unversioned hook under
`.git`:

```sh
scripts/check-local-pre-push-prereqs.sh
scripts/install-pre-push-hook.sh
```

The required Go toolchain must exactly match the patch version in `go.mod`.
`git`, `go`, and `actionlint` are the only required tools. Before invoking
them, the runner re-execs through `env -i`. It preserves only validated `HOME`,
`PATH`, `TMPDIR`, `LANG`, `USER`, and `SHELL`, and forces noninteractive Git
pagers/prompts. Cloud, proxy, signing, store, token, and password environment
variables are therefore unavailable to the checks. The gate never performs
remote Git operations, uploads, tags, or releases. Go may download
already-declared modules when they are absent from the local module cache.

Docker Desktop is also required. The Linux C ABI check uses the exact public
`golang:1.26.3@sha256:3bf5b04541eb4a37fe62aa1bc9c98a1dec09db9d2e79c1d2eb54e3c9d08dbca9`
linux/amd64 manifest. It runs with an empty temporary `DOCKER_CONFIG`, a
read-only source mount, `--rm`, and a temporary output mount; unavailable
Docker, daemon, image, or build fails the push. It builds
`./cgo_bridge` with read-only modules, trimmed paths, VCS stamping disabled,
and an empty Go build ID, then verifies both the `CGoFree` declaration and
exported ELF symbol.

## Exact checks

For one non-deletion branch update per `git push`, the hook runs:

```sh
git diff --check <remote-base> <exact-local-commit>
actionlint
go test ./... -count=1 -timeout 15m
go test -race ./... -count=1 -timeout 15m
go vet ./...
scripts/validate-linux-c-abi.sh
```

Multiple branch updates, tags, deletes, unresolved or non-ancestor remote
bases, concurrent runs, and toolchain mismatches fail closed. A stale lock is
recovered only when its recorded PID is no longer alive. The temporary
worktree must start and end at the exact pushed commit with no changes; cleanup
failure also turns the run into a failure. Push branches separately when each
needs validation.

Run the structural self-test without installing a hook:

```sh
scripts/test-local-pre-push-ci.sh
```

## Platform builds remain separate

Android and Apple artifact builds remain tag/release gates, not routine push
CI. The current build code fetches geo data, mutates `go.mod`/`go.sum` during
preparation, resolves `gomobile` at `@latest`, and does not pin an exact
Android NDK toolchain. A future release gate must first pin Go, gomobile, NDK,
Xray-core input, and geo-data input, then run only in a disposable worktree
with artifact outputs outside the source tree.

GitHub workflows are manual `workflow_dispatch` entry points. `build.yml`
uploads manual build artifacts only; its unreachable tag-release job was
removed. Publishing a GitHub Release is a separate provider-bound operation
and needs a reviewed manual workflow with explicit release-tag input,
artifact-provenance verification, and its own trust/authorization gate.
