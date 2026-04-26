# Tiny Secrets Manager

`tsm` is a Touch-ID-gated secrets manager for coding agents on macOS. Keep API keys, tokens, and passphrases in a local encrypted vault; unlock for 12 hours with a fingerprint, use them across the day. Secrets are stored in memory only.

## The problem

Agents need credentials all the time — for calling `aws`, `gh`, `psql`, `gcloud`, or simply `curl`ing API endpoints. Long-lived, static credentials sit in JSON files (insecurely on disk) or in a heavyweight secrets manager like 1Password.

1Password isn't great for this. The 1Password CLI `op` re-prompts for Touch ID on every credential read — sometimes several times in a row during a single agent turn.

Following the `ssh-agent` model, `tsm` offers a long-lived local daemon. When unlocked, it holds the decrypted master key in RAM. **One Touch ID at session start covers everything** for the next 12 hours — every agent subprocess, every MCP server, every shell command. And, individual secrets can be marked to require touch for every use.

## What you get

- **One Touch ID per session.** Daemon-held TTL, not per-process auth. Default 12h, configurable.
- **No cloud, no account, no subscription.** One binary, one encrypted file, the system Keychain. No vendor.
- **Per-secret confirm gate.** Mark high-value secrets `confirm: true` to force Touch ID on every access regardless of vault state.
- **Safe output modes.** `--raw` for pipes, `<(tsm get … --raw)` for process substitution (file-flag tools), `--to-file` for tools that demand a path. Refuses to write secrets to a TTY.
- **No secrets in `ps` or shell history.** Values are always read from stdin, a file, or the TUI — never a flag.
- **First-class agent integration.** `tsm run --env VAR=secret -- cmd` injects credentials into a subprocess for one invocation; `tsm get --format env|aws-credential-process|pgpass` produces tool-specific wire formats. A bundled Claude Code plugin (`plugin/`) ships a SessionStart hook, a permission allowlist, and an opinionated skill that teaches the agent which pattern to reach for.
- **Audit log.** Every access is logged with timestamp, secret id, and client id. `tsm log` to view.
- **Open source and small.** Auditable Swift daemon (~13 files), Go CLI, JSON-RPC over a Unix socket. No magic.

## How it compares to `op` (1Password CLI)

`op` is a strong tool with a much broader scope; tsm only makes sense if you want a narrow, local, agent-shaped tool.

| | tsm | op |
|---|---|---|
| Touch ID per session | One prompt for the whole TTL window | Re-prompts per CLI invocation, gated by app policy |
| Account / subscription | None | 1Password account required |
| Sync across devices | No (one local file; manual copy with recovery passphrase) | Yes |
| Sharing / shared vaults | No (personal-use only) | Yes |
| Agent integration | `tsm run` env injection + Claude Code plugin (skill, hook, allowlist) | `op run` |
| Per-secret "require touch" | Yes | Limited (controlled by 1Password app policy) |
| Plugin ecosystem (aws, gh, etc.) | Not yet — see [`docs/claude-code-integration.md`](docs/claude-code-integration.md) | Mature (`op plugin init`) |
| Item types | Secrets only | Secrets, SSH keys, identities, documents, … |
| Source available | Yes | No |
| Platforms | macOS (Apple Silicon) | macOS, Linux, Windows, mobile |

**Use `op` if** you want one tool for your whole identity layer across devices, with sharing, sync, and a mature plugin set.

**Use `tsm` if** you want a local-only credential vault sized for a developer machine and an agent's session, with one Touch ID covering many calls and no subscription.

## Requirements

- macOS with Touch ID (Apple Silicon recommended)
- Go 1.25+
- Swift 5.9+ (Xcode command-line tools)

## Build from source

```bash
# Daemon
cd tsmd
swift test                                    # ~83 tests
swift build -c release
cp .build/release/tsmd ~/.local/bin/tsmd
cd ..

# CLI
go test ./...
go build -o ~/.local/bin/tsm .
```

Make sure `~/.local/bin` is on your `$PATH`.

The daemon must be ad-hoc signed on Apple Silicon — `swift build` does this automatically. Don't strip the signature.

## Quick start

```bash
tsm init        # Generate master key, store in Keychain (Touch ID gates access)
tsm unlock      # Authenticate; vault stays unlocked for the configured TTL (default 12h)
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
tsm get openai-api-key                       # JSON to stdout
tsm get openai-api-key --raw | pbcopy        # raw value, refuses to write to a TTY
tsm get openai-api-key --to-file /tmp/key    # mode 0600, no trailing newline
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

### For Claude Code

Install the bundled plugin to give Claude Code first-class tsm support:

```bash
mkdir -p ~/.claude/plugins
ln -sf "$PWD/plugin" ~/.claude/plugins/tsm
```

The plugin:
- Runs `tsm ensure-daemon` at session start.
- Auto-approves read-only `tsm` commands (`list`, `get`, `run`, `status`, `log`, `lock`, `unlock`, `ensure-daemon`) so the agent does not prompt on every read.
- Ships an opinionated `credential-usage` skill that teaches the agent to discover credentials in the vault before asking the user.

