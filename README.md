# Tiny Secrets Manager

`tsm` is a tiny secrets manager for coding agents on macOS.

Coding agents need credentials for networked CLI tools and API calls.
Yet storing credentials unencrypted in `.env` and JSON files is insecure.
And heavyweight secrets managers like 1Password are architecturally mismatched for coding agents,
giving you Touch ID re-prompting on every credential read,
sometimes several times in a row during a single agent turn.

With `tsm`, credentials are stored in an encrypted vault file.
Touch ID unlocks the vault for 30 minutes,
with vault access isolated to a single shell or agent session.

And it's super lightweight, open source, and easy to verify.  
Bitwarden is 1.8 million lines of code, `tsm` is 3,000.

Unencrypted secrets are stored in memory only,
and auto-locks on screen lock or system sleep.

Values are always read from stdin, a file, or the TUI.
See [How to Handle Secrets on the Command Line](https://smallstep.com/blog/command-line-secrets/).

Sensitive secrets can be set to require Touch ID on every access.

What `tsm` defends against:

- **Same-user malware in a different session.** A LaunchAgent, browser-spawned helper, or process in a separate terminal pane that connects to the daemon socket while your main session is unlocked still has to Touch ID on its own — which prompts you visibly. Each session unlocks independently.
- **Absent user.** Auto-lock on screen lock and system sleep zeros the key, even if the TTL hasn't yet elapsed.
- **Secrets at rest.** Vault file is AES-GCM encrypted; the master key lives only in the macOS Keychain (Touch ID gated) and in daemon RAM while at least one session is unlocked.

Behind the scenes, `tsm` is a Go CLI, it uses JSON-RPC over a Unix socket to the `tsmd` Swift daemon, which is started on demand.
The model is similar to `ssh-agent`.

## Installation

Install with bun, npm, or pnpm. Either pulls a prebuilt, sigstore-signed binary (macOS arm64 only).

```bash
bun install -g @tashian/tsm
# or: npm install -g @tashian/tsm
# or: pnpm add -g @tashian/tsm
```

Verify provenance:

- The npm package page ([@tashian/tsm](https://www.npmjs.com/package/@tashian/tsm)) shows a sigstore-signed "Built and signed on GitHub Actions" badge linking to the source workflow run and the public transparency log entry.
- For programmatic checks against the npm registry: `npm view @tashian/tsm dist.attestations`.
- For the [GitHub Release](https://github.com/tashian/tsm/releases/latest) tarball: `gh attestation verify tsm_<version>_darwin_arm64.tar.gz --repo tashian/tsm`.

## For Claude Code

Install the bundled plugin to give Claude Code first-class tsm support. This repo is a single-plugin marketplace (`.claude-plugin/marketplace.json` at the root); from inside Claude Code:

```
/plugin marketplace add tashian/tsm
/plugin install tsm@tsm
```

The plugin:
- Auto-approves read-only and lifecycle `tsm` commands (`list`, `get`, `run`, `status`, `log`, `lock`, `unlock`) so the agent does not prompt on every read.
- Ships an opinionated `credential-usage` skill that teaches the agent to discover credentials in the vault before asking the user.

The `tsm` CLI auto-spawns the daemon on first use, so no SessionStart hook is needed.

## Quick start

```bash
tsm init        # Generate master key, store in Keychain (Touch ID gates access)
tsm unlock      # Authenticate; vault stays unlocked for the configured TTL (default 30m)
tsm status
```

### Adding secrets

`tsm add` takes the value from a file or stdin — never from a flag, to keep secrets out of shell history and `/proc/<pid>/cmdline`.

**From a file, with a confirm gate and tags:**

```bash
$ tsm add --name openai-api-key \
          --display-name "OpenAI API key" \
          --description "Production GPT-4 key" \
          --confirm \
          --tags openai,prod \
          --from-file ~/secrets/openai.txt
Secret 'OpenAI API key' added (id: openai-api-key).
```

**Piped from stdin:**

```bash
$ echo "ghp_abc123def456" | tsm add --name github-pat \
                                    --display-name "GitHub PAT" \
                                    --description "Read-only token for private repos" \
                                    --tags github
Secret 'GitHub PAT' added (id: github-pat).
```

### Listing

```bash
$ tsm list
  OpenAI API key [confirm] (openai, prod)
    id: openai-api-key
    Production GPT-4 key
  GitHub PAT (github)
    id: github-pat
    Read-only token for private repos
```

The display name is shown first; the kebab-case id (used for `tsm get`, env var derivation, and audit logs) is on the line beneath. Run `tsm add` with no flags to use the interactive TUI instead — it'll prompt for the display name and show a live "stored as: …" preview as you type.

### Retrieving

```bash
tsm get openai-api-key | pbcopy              # raw value to stdout, refuses to write to a TTY
tsm get openai-api-key --to-file /tmp/key    # mode 0600, no trailing newline
```

Inline in a one-shot command — the secret never appears in shell history or `ps`:

```bash
curl -H "Authorization: Bearer $(tsm get openai-api-key)" \
     https://api.openai.com/v1/models
```

### Running tools with vault-injected env vars

```bash
tsm run --env GITHUB_TOKEN=gh-pat -- gh pr list
tsm run --env OPENAI_API_KEY=openai-key -- openai api models.list
```

The env var lives only inside the child process; the parent shell is unaffected. `tsm run` is what `.mcp.json` configs should use to wrap MCP server commands so the server inherits credentials at startup.

### Output formatters

For tools that read credentials from a specific wire format:

```bash
tsm get aws-prod --format aws-credential-process > ~/.aws/credentials.json
tsm get pg-prod  --format pgpass                 > ~/.pgpass
tsm get gh-pat   --format "env GITHUB_TOKEN"     > /dev/shm/envfile
```

`tsm get --format` refuses to write to a TTY; always redirect.

## Build requirements

- macOS with Touch ID (Apple Silicon recommended)
- Go 1.25+
- Swift 5.9+ (Xcode command-line tools)

## Build from source

```bash
# Daemon
cd tsmd
swift test                                    # ~100 tests
swift build -c release
cp .build/release/tsmd ~/.local/bin/tsmd
cd ..

# CLI
go test ./...
go build -o ~/.local/bin/tsm .
```

(Make sure `~/.local/bin` is on your `$PATH`.)

The daemon must be ad-hoc signed on Apple Silicon — `swift build` does this automatically. Don't strip the signature.
