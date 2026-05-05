# tsm

Touch ID-gated secrets manager for macOS. The CLI talks to a small daemon (`tsmd`) that owns the encrypted vault, the macOS Keychain entry for the master key, and the `LocalAuthentication` Touch ID prompt.

## Install

```sh
# npm
npm install -g @tashian/tsm

# bun
bun install -g @tashian/tsm

# pnpm
pnpm add -g @tashian/tsm
```

This package is a thin shim. The actual binaries are pulled in via `optionalDependencies` based on your platform — currently only `@tashian/tsm-darwin-arm64` (Apple Silicon Macs).

After an upgrade, the running `tsmd` keeps serving until your sessions all hit their TTL and the daemon has been idle for 30 minutes — at which point it exits and the next `tsm` command spawns a fresh daemon from the new binary. If you want the new daemon immediately, run `tsm daemon stop`.

## Usage

```sh
tsm init                   # create a new vault
tsm add                    # add a secret (TUI)
tsm list                   # list secrets
tsm get GITHUB_TOKEN       # print a secret to stdout (rejects writing to a TTY)
tsm run -- ./script.sh     # exec a command with secrets in env
```

See [the project README on GitHub](https://github.com/tashian/tsm) for design notes, threat model, and the Claude Code plugin.

## Verifying provenance

Every release is built from a tagged commit on GitHub Actions and signed via [npm Trusted Publishing](https://docs.npmjs.com/trusted-publishers/) (sigstore-backed). To verify before installing:

```sh
npm audit signatures
```

The corresponding GitHub Release tarball also carries an [Artifact Attestation](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations):

```sh
gh attestation verify tsm_<version>_darwin_arm64.tar.gz --repo tashian/tsm
```

## License

MIT — see [LICENSE](./LICENSE).
