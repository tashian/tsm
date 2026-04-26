# Releasing tsm

Releases happen on tag push. The `release.yml` workflow on `macos-14` builds both binaries, creates a GitHub Release with provenance attestations, and publishes two npm packages with sigstore-signed provenance via npm Trusted Publishing.

The workflow uses no long-lived secrets — auth is via GitHub OIDC for both attestations and npm.

## One-time setup

These steps must be done once before the first real release.

### 1. Reserve npm names with placeholder publishes

npm Trusted Publishing requires the package to already exist on the registry. Publish placeholder `0.0.1` versions interactively from your machine:

```sh
npm login    # personal account; uses 2FA. Required.

# Platform package — empty bin/ is fine, this is a placeholder.
( cd npm/darwin-arm64 && npm publish --access public --dry-run )    # sanity-check first
( cd npm/darwin-arm64 && npm publish --access public )

( cd npm/wrapper && npm publish --access public --dry-run )
( cd npm/wrapper && npm publish --access public )
```

After this you'll have `@tashian/tsm@0.0.0` and `@tashian/tsm-darwin-arm64@0.0.0` on the registry. They're harmless placeholders.

### 2. Configure Trusted Publishing for both packages

For *each* of the two packages:

1. Go to `https://www.npmjs.com/package/@tashian/<pkg>/access`
2. Scroll to "Trusted Publisher" → "Add trusted publisher"
3. Set:
   - Publisher: GitHub Actions
   - Organization or user: `tashian`
   - Repository: `tsm`
   - Workflow filename: `release.yml`
   - Environment: *(leave blank)*

Once both packages have a trusted publisher configured, the workflow can publish without an `NPM_TOKEN` secret.

### 3. Confirm 2FA on the npm account

Trusted Publishing requires 2FA on the publishing account. Check at `https://www.npmjs.com/settings/<user>/profile`.

## Cutting a release

```sh
# 1. Make sure main is green and you're at the commit you want to release.
git switch main
git pull
gh run list --branch main --limit 1   # confirm CI is green

# 2. Tag and push. The workflow runs automatically.
VERSION=0.1.0
git tag -a "v${VERSION}" -m "tsm v${VERSION}"
git push origin "v${VERSION}"

# 3. Watch the run.
gh run watch
```

The workflow:

1. Builds `tsm` (Go) and `tsmd` (Swift, ad-hoc signed by `swift build`)
2. Tarballs both into `tsm_<version>_darwin_arm64.tar.gz` with `checksums.txt`
3. Attests build provenance via `actions/attest-build-provenance` (sigstore, public transparency log)
4. Creates a GitHub Release with auto-generated notes from PRs since the previous tag
5. Publishes `@tashian/tsm-darwin-arm64@<version>` first (so the wrapper's `optionalDependencies` resolve)
6. Publishes `@tashian/tsm@<version>` second
7. Both npm publishes carry provenance attestations linking back to this exact workflow run

## Local dry-run

Before tagging, you can sanity-check the build and packaging on your laptop:

```sh
just release-dryrun 0.0.0-dev
ls -lh dist/release/

# Inspect the tarball.
tar -tzvf dist/release/tsm_0.0.0-dev_darwin_arm64.tar.gz
```

Local builds do **not** mint provenance attestations — those require the workflow's OIDC identity. Use the dry-run only to verify packaging.

## Verifying a release after the fact

```sh
# GitHub Artifact Attestation on the release tarball
gh attestation verify tsm_0.1.0_darwin_arm64.tar.gz --repo tashian/tsm

# npm package provenance
npm view @tashian/tsm@0.1.0
npm audit signatures      # in a project that depends on it
```

## Troubleshooting

**"OIDC token has insufficient scope"** — `id-token: write` is missing from the workflow's `permissions:` block. Should already be set; don't remove it.

**"npm error code E403" on publish** — Trusted Publishing isn't fully configured for the package, or the workflow filename in the npm settings doesn't match `release.yml`. Re-check step 2 above.

**Wrapper installs but `tsm: command not found`** — `optionalDependencies` was skipped. The user installed with `--no-optional`, or has an unsupported platform. The shim prints a clear error in that case; if it doesn't, the platform key in `npm/wrapper/shim.js` may need extending.

**Daemon won't start ("tsmd not found")** — `TSM_TSMD_BIN` is being unset somewhere, or the platform package didn't install. Check `npm ls @tashian/tsm-darwin-arm64`.
