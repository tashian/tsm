# Tiny Secrets Manager

Coding agents need credentials all the time — `aws`, `gh`, `psql`, `gcloud`, MCP servers, anything a skill shells out to. Today those credentials sit in plaintext in `~/.aws/credentials`, `~/.config/gh/hosts.yml`, `~/.pgpass`, `.env` files, and `.mcp.json`. None of it is biometric-gated.

`tsm` is an MCP-aware Touch-ID-gated secrets manager for macOS. Keep API keys, tokens, and passphrases in a local encrypted vault; unlock once with a fingerprint, use them across the day from the CLI or (eventually) MCP-aware agents.

## Why I built this

Coding agents need credentials all the time — `aws`, `gh`, `psql`, `gcloud`, MCP servers, anything a skill shells out to. Today those credentials sit in plaintext in `~/.aws/credentials`, `~/.config/gh/hosts.yml`, `~/.pgpass`, `.env` files, and `.mcp.json`. None of it is biometric-gated. Claude Code itself ships no built-in vault.

I tried doing this with `op` (the 1Password CLI). Every credential access in a Claude Code session re-prompts for Touch ID — sometimes several times in a row. A single agent task that calls `gh` then `aws` then `psql` becomes a Touch ID drumroll.

`tsm` offers a long-lived local daemon, following the `ssh-agent` model. When unlocked, it holds the decrypted master key in RAM. **One Touch ID at session start covers everything** for the next 12 hours — every agent subprocess, every MCP server, every shell command. And, individual secrets can be marked to require touch for every use.

## What you get

- **One Touch ID per session.** Daemon-held TTL, not per-process auth. Default 12h, configurable.
- **No cloud, no account, no subscription.** One binary, one encrypted file, the system Keychain. No vendor.
- **Per-secret confirm gate.** Mark high-value secrets `confirm: true` to force Touch ID on every access regardless of vault state.
- **Safe output modes.** `--raw` for pipes, `<(tsm get … --raw)` for process substitution (file-flag tools), `--to-file` for tools that demand a path. Refuses to write secrets to a TTY.
- **No secrets in `ps` or shell history.** Values are always read from stdin, a file, or the TUI — never a flag.
- **MCP-native.** (coming soon) `vault_list`, `vault_get`, `vault_status` so an agent can request credentials in-conversation. Read-only by design — agents can't mutate the vault.
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
| MCP server (coming soon) | Yes (`tsm mcp`) | No |
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

