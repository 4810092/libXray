# Signed local-CI attestation

Routine validation is performed locally by the versioned pre-push gate. A
successful full gate writes a canonical payload for the exact commit being
pushed, signs it using SSHSIG, stores it as a Git note under
`refs/notes/ekhovpn-local-ci/v1`, and pushes that note before the branch.

The only provider workflow which mutates repository state, `Go module mirror
tag`, first verifies a note for the exact workflow SHA. A note cannot be reused
for another commit, another gate manifest, another base range, or another
signing namespace.

## One-time local setup

Generate one dedicated Ed25519 key outside every checkout. Keep the private
key owned by the signing user, mode `0600`, with a single hard link. Then run:

```bash
scripts/install-pre-push-hook.sh \
  --attestation-key /absolute/path/to/private-ed25519-key \
  --attestation-identity ekhovpn-local-ci
```

The installer records only the absolute key path and identity in local Git
configuration. It does not add the key to the repository or to a global hooks
directory.

Configure the corresponding public key in the `release-attestation` GitHub
environment secret `EKHO_LOCAL_CI_ALLOWED_SIGNERS`, in OpenSSH
`allowed_signers` form. Restrict that environment to the `main` branch:

```text
ekhovpn-local-ci ssh-ed25519 AAAA... local-ci-attestation
```

The key is an operator trust boundary. Rotate it by adding the new public key
to the secret, switching installed local hooks to the new private key, then
removing the retired public key after all in-flight releases complete.

## Failure and recovery

If the note publication fails, the branch push is rejected and the local note
is removed. If provider verification fails, no mirror tag is created. Do not
use `--no-verify` to bypass a rejected branch push. A maintainer may inspect
the exact evidence with:

```bash
git notes --ref refs/notes/ekhovpn-local-ci/v1 show <commit-sha>
```
