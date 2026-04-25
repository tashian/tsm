# tsm -- Tiny Secrets Manager

Design document for a biometric-authenticated secrets manager built for AI coding agents.

## Problem

AI coding agents frequently need API keys and credentials to perform tasks on behalf of the user -- generating images, calling external APIs, deploying code. Today, these secrets are either:

- Pasted into the terminal (leaks to shell history and session logs)
- Stored in `.env` files (plaintext on disk, easily committed)
- Managed by external tools that aren't integrated with agent workflows
- Set as environment variables (bad idea for many reasons)

None of these approaches give the user biometric-gated control over which secrets an agent can access, or when.

## Solution

`tsm` is a local secrets manager that:

1. Stores secrets in an encrypted vault on disk
2. Uses biometric authentication to gate access, with per-secret confirmation
3. Runs as a daemon (like `ssh-agent`) that stays open across agent sessions
4. Exposes secrets to agents via MCP tools and a CLI
5. Works with any MCP-capable agent, with first-class Claude Code integration via plugin

## Architecture

### Component Overview

```
┌─────────────────┐   ┌─────────────────┐   ┌──────────────┐
│ Claude Code (1) │   │ Claude Code (2) │   │ Cursor / any │
│  plugin: tsm    │   │  plugin: tsm    │   │  MCP client  │
└───────┬─────────┘   └───────┬─────────┘   └──────┬───────┘
        │    stdio (MCP)      │                     │
        └─────────┬───────────┘                     │
                  ▼                                 ▼
          ┌───────────────┐                 ┌───────────────┐
          │ tsm mcp       │                 │ tsm mcp       │
          │ (Go, thin)    │                 │ (Go, thin)    │
          └───────┬───────┘                 └───────┬───────┘
                  │          Unix socket            │
                  └─────────────┬───────────────────┘
                          ┌─────┴──────┐
                          │   tsmd     │  (Swift daemon)
                          │            │  holds decrypted secrets
                          │            │  handles Touch ID
                          │            │  manages TTL
                          └──┬──────┬──┘
                             │      │
                             ▼      ▼
                        ┌────────┐ ┌───────────┐
                        │macOS   │ │ vault.enc │
                        │Keychain│ │ (local)   │
                        │(master │ │           │
                        │ key)   │ │           │
                        └────────┘ └───────────┘
```

### Binaries

| Binary | Language | Role |
|--------|----------|------|
| `tsm` | Go | CLI, MCP server mode, daemon lifecycle |
| `tsmd` | Swift | Daemon: Touch ID, Keychain, CryptoKit, vault state, TTL |

The Go binary is the single user-facing entry point. It manages the daemon and connects to it over a Unix domain socket. This follows the `ssh-agent` pattern: a persistent daemon holds sensitive material in memory while thin clients communicate over a socket.

### Daemon Lifecycle

The daemon follows the `ssh-agent` model:

1. Any `tsm` command calls `ensureDaemon()` first
2. `ensureDaemon()` checks `$TSM_SOCK` (or default socket path) -- if absent or stale, spawns `tsmd`
3. `tsmd` runs in the background, listens on the Unix socket
4. Multiple `tsm` processes (MCP servers, CLI commands) connect concurrently
5. The daemon locks the vault after the TTL expires (default: 12 hours)
6. The daemon remains as a lightweight idle process after locking (exits only via `tsm daemon stop` or `daemon.shutdown`)

When an agent session starts, the Claude Code plugin hook runs `tsm ensure-daemon`. This only ensures the daemon process is running — it does not attempt to unlock the vault. If the vault is locked, the first `vault_get` call will trigger authentication. If already unlocked, it's a no-op.

## Vault Storage & Encryption

### Vault File Format

A single encrypted blob containing all secrets and configuration:

```json
{
  "version": 1,
  "secrets": [
    {
      "name": "gemini-api-key",
      "display_name": "Gemini API key",
      "value": "AIza...",
      "description": "Google Gemini API key for Nano Banana image generation",
      "confirm": false,
      "tags": ["google", "ai", "images"],
      "created": "2026-03-05T10:00:00Z",
      "updated": "2026-03-05T10:00:00Z"
    },
    {
      "name": "github-pat",
      "display_name": "GitHub PAT",
      "value": "ghp_...",
      "description": "GitHub personal access token for private repos",
      "confirm": true,
      "tags": ["github", "git"],
      "created": "2026-03-05T10:00:00Z"
    }
  ],
  "config": {
    "ttl_hours": 12
  }
}
```

### On-Disk Envelope

The vault file is a JSON envelope wrapping the encrypted blob:

```json
{
  "version": 1,
  "algorithm": "aes-256-gcm",
  "recovery": {"salt": "<base64>", "iterations": 600000},
  "nonce": "<base64>",
  "ciphertext": "<base64>"
}
```

The `version` field tracks the envelope schema. The `algorithm` field identifies the cipher used for encryption, enabling future algorithm migration without conflating schema changes with crypto changes.

### Encryption

- Algorithm: AES-256-GCM (initial release)
- A random 256-bit master key is generated on first run
- The master key is stored in the platform's secure key storage, protected by biometric authentication
- The master key never leaves the device

**macOS implementation** (initial release):
- AES-256-GCM via Apple CryptoKit (native, no dependencies)
- Master key stored in macOS Keychain with `kSecAttrAccessControl` set to `biometryCurrentSet` (requires Touch ID, invalidates if fingerprints change)
- Keychain item: Service `com.tsm.vault`, Account `master-key`
- Local Keychain only (no iCloud Keychain sync)

### Algorithm Migration

The `algorithm` field in the vault envelope enables transparent encryption algorithm upgrades:

1. **Decryption dispatches on the envelope's `algorithm` field.** The daemon reads the field and selects the corresponding decrypt path. Old algorithms are supported for reading indefinitely.
2. **Encryption always uses the latest algorithm.** Any write (add, edit, remove) re-encrypts the entire vault with the current algorithm and updates the envelope's `algorithm` field.
3. **No explicit migration command needed.** The vault is rewritten on every mutation, so upgrading happens automatically on the next secret change. Users who want to force it can run `tsm edit` on any secret (even a no-op change) or a future `tsm migrate` if warranted.

The master key is algorithm-independent — it's a 256-bit symmetric key stored in Keychain, usable with any cipher that accepts a 256-bit key (AES-256-GCM, XChaCha20-Poly1305, etc.). No Keychain migration is needed when swapping ciphers.

Similarly, the recovery passphrase derives a 256-bit key via PBKDF2, which is also algorithm-independent. Changing the KDF itself (e.g., PBKDF2 → Argon2) is a separate, harder migration that requires the user to re-enter their passphrase.

**What would force a harder migration:**
- Changing key size (e.g., to a 512-bit cipher) — requires generating a new master key, replacing the Keychain entry, and re-deriving from the recovery passphrase
- Changing KDF (e.g., PBKDF2 → Argon2) — requires the user's passphrase to re-derive under the new KDF
- Neither is anticipated for the initial release

### Confirm Constraint

Secrets have an optional `confirm` flag (borrowing from ssh-agent's per-key confirm constraint):

| `confirm` | Behavior |
|-----------|----------|
| `false` (default) | Available whenever the vault is unlocked. Authentication required once per session. |
| `true` | Authentication required **every time** the secret is retrieved, regardless of vault state. |

Confirm is appropriate for secrets with billing implications (API keys that cost money per call) or elevated privileges (admin tokens). The daemon handles confirmation using whatever authentication backend is available on the platform (Touch ID, Windows Hello, YubiKey, passphrase fallback).

### Passphrase Fallback

If biometric authentication fails repeatedly (3 consecutive failures), the daemon falls back to passphrase authentication — but only if a recovery passphrase was set during `tsm init`. The fallback flow:

1. Touch ID fails 3 times (user cancels, sensor error, etc.)
2. Daemon returns error with `"data": {"fallback": "passphrase"}`
3. CLI prompts for recovery passphrase via secure TUI input
4. CLI sends `vault.unlock` with `{"passphrase": "..."}` param
5. Daemon derives key via PBKDF2, verifies against vault, unlocks if correct

If no recovery passphrase was set, biometric failure returns an error with guidance to re-enroll fingerprints or run `tsm init --recover`.

### File Locations (XDG-Compliant)

| Purpose | Path |
|---------|------|
| Binaries | `${HOME}/.local/bin/tsm`, `tsmd` |
| Config | `${XDG_CONFIG_HOME:-~/.config}/tsm/config.json` |
| Data (vault) | `${XDG_DATA_HOME:-~/.local/share}/tsm/vault.enc` |
| Data (access log) | `${XDG_DATA_HOME:-~/.local/share}/tsm/access.log` |
| Runtime (socket) | `$TSM_AUTH_SOCK` or `${XDG_RUNTIME_DIR:-${TMPDIR}}/tsm/vault.sock` |

### Recovery

On first `tsm init`, the user can optionally set a recovery passphrase. This passphrase derives the master key via PBKDF2-HMAC-SHA256 (600,000 iterations, random 32-byte salt stored alongside the vault). The passphrase is never stored -- only the derived key goes into Keychain.

PBKDF2-HMAC-SHA256 was chosen because both Go (`golang.org/x/crypto/pbkdf2`) and Swift (`CommonCrypto/CCKeyDerivationPBKDF`) support it natively with no third-party dependencies.

Recovery scenario (vault file copied to a new Mac):
1. User copies `vault.enc` to the new machine (USB, AirDrop, etc.)
2. `tsm unlock` fails (no master key in local Keychain)
3. `tsm init --recover` prompts for recovery passphrase
4. Derives master key via PBKDF2, stores in local Keychain with Touch ID protection
5. Future unlocks use Touch ID

## MCP Interface

Three tools, deliberately minimal:

### `vault_list`

Returns ids, display names, descriptions, and confirm flags of all secrets. Never returns values.

```json
// Response
[
  {
    "name": "gemini-api-key",
    "display_name": "Gemini API key",
    "description": "Google Gemini API key for Nano Banana image generation",
    "confirm": false,
    "tags": ["google", "ai", "images"]
  }
]
```

### `vault_get`

Retrieves a secret value by id (the `name` field, kebab-case). The `display_name` is **not** an alias — agents must use the id.

- `confirm: false`: returns immediately if vault is unlocked
- `confirm: true`: daemon prompts for authentication before returning; fails with guidance if no terminal is available

```json
// Request
{"name": "gemini-api-key"}
// Response
{"name": "gemini-api-key", "value": "AIza..."}
```

### `vault_status`

Returns vault state. No sensitive data.

```json
{
  "locked": false,
  "ttl_remaining_seconds": 27120,
  "secret_count": 5
}
```

## CLI Commands

### Management Commands (TUI)

Interactive commands using the Charm TUI stack (huh, lipgloss, bubbletea). These present a friendly walkthrough-style interface with styled prompts, radio selects, and secure input fields (echo disabled via termios).

| Command | Action |
|---------|--------|
| `tsm init` | Create vault, generate master key, store in Keychain, optional recovery passphrase |
| `tsm init --recover` | Recover vault on new device using recovery passphrase |
| `tsm add` | Add a secret (name, description, confirm flag, value via secure TUI input) |
| `tsm remove <name>` | Remove a secret (with confirmation) |
| `tsm edit <name>` | Modify a secret's value, description, or confirm flag |
| `tsm list` | List secrets (names, descriptions, confirm flags -- never values) |
| `tsm lock` | Lock the vault immediately |
| `tsm unlock` | Unlock the vault (triggers Touch ID) |
| `tsm status` | Show vault state, TTL remaining, daemon PID |
| `tsm config` | View/set configuration (TTL, etc.) |
| `tsm reset` | Destroy vault, config, log, and Keychain entry (requires auth) |

### Infrastructure Commands

| Command | Action |
|---------|--------|
| `tsm get <name>` | Retrieve a secret value (`--raw`, `--to-file`, or JSON) |
| `tsm ensure-daemon` | Start daemon if not running (used by hooks) |
| `tsm mcp` | Run as MCP server (stdio mode, used by agent config) |
| `tsm schema` | Dump MCP tool schemas as JSON (agent discoverability) |
| `tsm log` | View access log (tail by default, `--json` for full dump) |
| `tsm version` | Print version |
| `tsm update` | Check for / install updates |

### Secret Input Safety

Secrets never touch shell history or agent session logs:

- **TUI mode** (`tsm add`): Secure input field with echo disabled. Value goes directly to the daemon over the Unix socket.
- **Pipe mode** (`echo $SECRET | tsm add --name foo --no-input`): Reads from stdin. For agent-driven or scripted use.
- **File mode** (`tsm add --name foo --from-file /path/to/key`): Reads value from a file.
- **Never as a flag value**: `tsm add --value <secret>` is explicitly not supported. The `--value` flag does not exist.

### Secret Output Safety

Retrieving secrets safely is just as important as storing them. `tsm get` supports output modes that keep secrets out of `/proc/<pid>/cmdline` and shell history:

**Raw mode** (`--raw`): Writes just the secret value to stdout with no framing, newline, or JSON wrapper. Designed for composability with process substitution and pipes:

```bash
# Process substitution -- secret never appears in ps
curl --cacert <(tsm get ca_cert --raw) https://example.com

# Password file flags
step-ca --password-file <(tsm get ca_password --raw) $(step path)/config/ca.json

# Pipe into a command's stdin
tsm get api_key --raw | some-tool --token-stdin
```

Because `tsm get` is an external binary (not a shell builtin), the process substitution `<(tsm get ...)` is safe — the secret is never interpolated into any command string. The secret travels: daemon -> Unix socket -> `tsm` process -> file descriptor -> consuming process. No secret appears in any `/proc/<pid>/cmdline`.

**Ephemeral credential file** (`--to-file <path>`): Writes the secret to a file with mode 0600, suitable for tools that require a credential file path. Combined with a tmpfs or `mktemp`, this keeps secrets off persistent storage:

```bash
# Write to a temporary file on tmpfs (Linux) or a ramdisk
tsm get client_key --to-file /dev/shm/client.key
curl --key /dev/shm/client.key https://example.com
rm /dev/shm/client.key

# Or use it inline with a subshell that cleans up
KEYFILE=$(mktemp) && tsm get client_key --to-file "$KEYFILE" && curl --key "$KEYFILE" https://example.com; rm -f "$KEYFILE"
```

The `--to-file` flag:
- Creates the file with owner-only permissions (mode 0600) before writing
- Overwrites the file if it already exists (does not append)
- Writes only the raw secret value (no JSON, no newline)
- Fails if the parent directory does not exist

**Default mode** (no flags): Returns JSON to stdout (`{"name": "...", "value": "..."}`), consistent with other `tsm` commands. Suitable for programmatic consumption by scripts that parse JSON.

**Never to terminal**: If stdout is a TTY and `--raw` is used, `tsm get` refuses with an error and a suggestion to pipe or redirect. This prevents accidental display of secrets in scrollback history.

## CLI Design: Human and Agent Considerations

This design references two CLI design guides:
- [Command Line Interface Guidelines](https://clig.dev) (human-focused)
- [Rewrite Your CLI for AI Agents](https://justin.poehnelt.com/posts/rewrite-your-cli-for-ai-agents/) (agent-focused)

It also references my blog [How to Handle Secrets on the Command Line](https://smallstep.com/blog/command-line-secrets/).

### Where the Guides Agree

- Never pass secrets via flags (both cite shell history and `ps` exposure)
- Provide `--json` for structured output
- Support `--dry-run` for previewing destructive actions
- Use standard exit codes (0 success, non-zero failure)
- Provide help text and documentation

### Where the Guides Conflict and How tsm Resolves Them

**Output formatting.** The human guide says detect TTY and show colorful, formatted output by default. The agent guide says optimize for structured, predictable JSON. tsm resolution: TTY gets styled tables (via lipgloss); non-TTY and `--json` get structured JSON. The MCP interface always returns JSON -- agents use MCP, not the CLI.

**Input style.** The human guide says prefer flags for clarity and prompt for missing args. The agent guide says accept `--json` raw payloads and never prompt. tsm resolution: TUI for interactive use (`tsm add`); `--no-input` mode with flags/stdin/file for scripted and agent-driven use. MCP tools accept structured JSON natively.

**Error messages.** The human guide says rewrite errors into actionable human guidance ("try running X instead"). The agent guide says return structured error objects with codes. tsm resolution: errors include both a machine-readable `code` field and a human-readable `message` field. Human mode appends suggestions; `--json` mode returns the structured object.

```json
{
  "error": {
    "code": "VAULT_LOCKED",
    "message": "Vault is locked. Run 'tsm unlock' or authenticate via Touch ID."
  }
}
```

**Discoverability.** The human guide says examples-first help text with `-h`. The agent guide says runtime schema introspection. tsm resolution: both. `-h` shows concise help with examples; `tsm schema` dumps MCP tool schemas as JSON for agent consumption.

**Safety and confirmation.** The human guide says confirm dangerous actions interactively. The agent guide says use `--dry-run` and treat agent input as adversarial. tsm resolution: `tsm remove` confirms interactively by default; `--force` skips confirmation; `--dry-run` previews the action. Agent inputs via MCP are validated (no path traversal in secret names, no control characters, name length limits).

### Input Validation (Agent Safety)

Each secret has two name fields:

| Field | Purpose | Validation |
|-------|---------|------------|
| `name` (id) | Stable identifier used for `tsm get`, env var derivation, audit logs, MCP calls, JSON keys. Always kebab-case. | `^[a-z0-9]+(-[a-z0-9]+)*$`, 1–128 chars, case-insensitive uniqueness |
| `display_name` | Cosmetic label shown in `tsm list`. Free-text, optional. | 0–256 chars, no control characters |

When a user runs `tsm add`, the CLI prompts for a human-readable name (e.g. "OpenAI API key"). The display name is stored verbatim, and the id is derived by **kebab-casing**:

1. Lowercase
2. Replace runs of non-alphanumeric characters with a single `-`
3. Trim leading/trailing `-`
4. Reject if empty or > 128 chars after normalization

Examples: `"OpenAI API key"` → `openai-api-key`; `"GitHub PAT"` → `github-pat`; `"Carl's prod token!"` → `carl-s-prod-token`.

The id is the primary key — `tsm get`, `tsm edit`, `tsm remove`, and MCP `vault_get` all take the id, not the display name. On id collision, `tsm add` rejects with a helpful error rather than auto-suffixing.

## Distribution

### Installation Methods

| Method | Command | Audience |
|--------|---------|----------|
| npm | `npm install -g @tsm/cli` | Most users, any platform |
| Homebrew | `brew install tsm` | macOS users |
| GitHub Releases | Download binary | Manual install, CI |
| Source | `go build` + `swift build` | Contributors |

The npm package bundles pre-built native binaries for the user's OS and architecture (following the gws pattern). On non-macOS platforms, `tsmd` is absent and `tsm` prints a clear error about platform support.

### Self-Bootstrapping (Plugin Hook)

The Claude Code plugin hook can bootstrap installation:

```
$ tsm ensure-daemon
[tsm] Checking installation...
[tsm] tsm v0.1.0 not found in ~/.local/bin
[tsm] Detected: macOS 26.3 arm64 (Apple Silicon + Touch ID)
[tsm] Downloading tsm v0.1.0 from github.com/you/tsm/releases...
[tsm] Verifying checksum...
[tsm] Installing tsm  → ~/.local/bin/tsm
[tsm] Installing tsmd → ~/.local/bin/tsmd
[tsm] Installed successfully
[tsm]
[tsm] Note: ensure ~/.local/bin is in your PATH.
[tsm]   fish: fish_add_path ~/.local/bin
[tsm]   zsh:  echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
[tsm]
[tsm] Run 'tsm init' to create your vault.
```

The bootstrap script:
- Checks `uname -m` and `uname -s` (fails on non-ARM64 or non-macOS)
- Verifies SHA256 checksum of downloaded binaries
- Respects `XDG_BIN_HOME` if set, falls back to `~/.local/bin`
- Never modifies shell config files -- only advises
- Logs every action with `[tsm]` prefix
- Checks for updates (cached for 24h) but never auto-updates

### Platform Support

Initial release: macOS ARM64 (Apple Silicon with Touch ID) only.

The architecture anticipates cross-platform support via the transport-agnostic protocol:

| Platform | Daemon | Auth Backend | Transport | Key Storage |
|----------|--------|-------------|-----------|-------------|
| macOS | Swift (`tsmd`) | Touch ID | Unix socket | Keychain |
| Linux | TBD | YubiKey, FIDO2, passphrase | Unix socket | Linux kernel keyring, `systemd-credentials`, or file |
| Windows | TBD | Windows Hello | Named pipe | DPAPI |

The Go CLI is cross-platform. Only the daemon binary is platform-specific. The `daemon.capabilities` method lets the CLI adapt to whatever the local daemon supports.

## Agent Integrations

### Claude Code Plugin

```
tsm-claude-code-plugin/
  .claude-plugin/
    plugin.json
  .mcp.json
  hooks/
    hooks.json
  skills/
    vault-usage/
      skill.md
```

`.mcp.json`:
```json
{
  "tsm": {
    "command": "tsm",
    "args": ["mcp"]
  }
}
```

`hooks/hooks.json`:
```json
{
  "hooks": {
    "SessionStart": [{
      "matcher": "startup",
      "hooks": [{
        "type": "command",
        "command": "tsm ensure-daemon"
      }]
    }]
  }
}
```

`skills/vault-usage/skill.md`:
```markdown
When you need API keys or credentials, use the vault_list tool to see
what's available. Use vault_get to retrieve them by name. Never log,
display, or include secret values in your output to the user. Use them
only in the specific API call or command that requires them.
```

### Other Agents

| Agent | Integration |
|-------|-------------|
| Cursor | `.cursor/mcp.json` referencing `tsm mcp` |
| Codex | `AGENTS.md` with CLI usage instructions |
| Any MCP client | `tsm mcp` as stdio MCP server |
| Scripts / CI | `tsm get <name> --raw`, `--to-file`, or `--json` via CLI |

## Configuration

`${XDG_CONFIG_HOME:-~/.config}/tsm/config.json`:

```json
{
  "ttl_hours": 12,
  "update_check": true,
  "update_check_interval_hours": 24
}
```

Configurable via `tsm config set ttl_hours 8` or by editing the file directly.

Precedence (highest to lowest):
1. Flags (`--ttl`)
2. Environment variables (`tsm_TTL_HOURS`)
3. Config file
4. Defaults

## Daemon Socket Protocol

JSON-RPC 2.0 over a local transport. Simple request/response, client-driven (daemon never sends unsolicited messages). Maximum message size: 1 MB.

### Transport

The wire protocol is transport-agnostic. Platform-specific transports:

| Platform | Transport | Location |
|----------|-----------|----------|
| macOS, Linux | Unix domain socket | `$TSM_AUTH_SOCK` or `${XDG_RUNTIME_DIR:-${TMPDIR}}/tsm/vault.sock` |
| Windows | Named pipe | `\\.\pipe\tsm-vault` |

The `TSM_AUTH_SOCK` environment variable (analogous to `SSH_AUTH_SOCK`) overrides the default transport location. The Go CLI sets this when spawning the daemon.

Access control is enforced by the transport: Unix socket permissions (owner-only) on macOS/Linux, SDDL ACLs on Windows.

### Wire Format

```json
// Request
{"jsonrpc": "2.0", "method": "vault.get", "params": {"name": "gemini_api_key"}, "id": 1}

// Response (success)
{"jsonrpc": "2.0", "result": {"name": "gemini_api_key", "value": "AIza..."}, "id": 1}

// Response (error -- auth-backend-agnostic)
{"jsonrpc": "2.0", "error": {"code": -32001, "message": "Vault is locked", "data": {"auth_method": "touchid"}}, "id": 1}

// Response (error -- confirm required)
{"jsonrpc": "2.0", "error": {"code": -32002, "message": "Authentication required", "data": {"auth_method": "touchid"}}, "id": 1}
```

Error codes:
- `-32001`: Vault is locked
- `-32002`: Authentication required (confirm constraint)
- `-32003`: Secret not found
- `-32600` to `-32700`: Standard JSON-RPC errors

The `data.auth_method` field is informational — it tells clients what kind of authentication the daemon will use, so they can display appropriate guidance. Clients must not branch on this value for protocol logic.

### Capability Discovery

```json
// Request
{"jsonrpc": "2.0", "method": "daemon.capabilities", "id": 1}

// Response
{
  "jsonrpc": "2.0",
  "result": {
    "protocol_version": 1,
    "auth_backends": ["touchid"],
    "features": ["confirm", "access-log"]
  },
  "id": 1
}
```

The Go CLI calls `daemon.capabilities` on first connection to adapt behavior to the platform-specific daemon. This avoids hardcoding assumptions about authentication backends or available features.

Future `auth_backends` values: `"touchid"`, `"windows-hello"`, `"yubikey"`, `"passphrase"`.

### Methods

- `vault.list` -- list secrets (no values)
- `vault.get` -- retrieve a secret value (may trigger confirm authentication)
- `vault.add` -- add a secret
- `vault.remove` -- remove a secret
- `vault.edit` -- modify a secret
- `vault.status` -- vault state
- `vault.lock` -- lock the vault
- `vault.unlock` -- unlock (authentication method determined by daemon)
- `vault.reset` -- destroy vault, config, log, and Keychain entry (requires auth, daemon shuts down after)
- `daemon.capabilities` -- protocol version, auth backends, features
- `daemon.shutdown` -- graceful exit

The `vault.unlock` method accepts optional `params`:

```json
// Biometric platforms (macOS, Windows): params omitted, daemon prompts natively
{"jsonrpc": "2.0", "method": "vault.unlock", "id": 1}

// Passphrase fallback (Linux without biometrics, recovery):
{"jsonrpc": "2.0", "method": "vault.unlock", "params": {"passphrase": "..."}, "id": 1}
```

### Client Identity (Optional)

Clients may include a `client_id` in any request for audit logging:

```json
{"jsonrpc": "2.0", "method": "vault.get", "params": {"name": "gemini_api_key", "client_id": "claude-code/pid:12345"}, "id": 1}
```

This is advisory — the daemon logs it but does not enforce it. Useful for answering "which agent accessed this secret and when?"

## Access Logging

The daemon logs all secret access events to `${XDG_DATA_HOME:-~/.local/share}/tsm/access.log`. Each line is a JSON object:

```json
{"ts": "2026-03-08T14:30:00Z", "method": "vault.get", "secret": "gemini_api_key", "client_id": "claude-code/pid:12345", "result": "ok"}
{"ts": "2026-03-08T14:30:05Z", "method": "vault.get", "secret": "github_pat", "client_id": "claude-code/pid:12345", "result": "confirm_required"}
{"ts": "2026-03-08T14:30:07Z", "method": "vault.get", "secret": "github_pat", "client_id": "claude-code/pid:12345", "result": "ok"}
{"ts": "2026-03-08T14:31:00Z", "method": "vault.unlock", "client_id": "cli/pid:67890", "result": "ok"}
```

Logged events:
- `vault.get` — which secret, who asked, success or failure reason
- `vault.unlock` / `vault.lock` — state transitions
- `vault.add` / `vault.remove` / `vault.edit` — mutations (values never logged)

The log is append-only. The daemon rotates it when it exceeds 10 MB (keeps one `.1` backup). Viewable via `tsm log` (tail) or `tsm log --json` (full dump).

## Reset

`tsm reset` performs a full teardown of all tsm state, returning the system to a pre-`tsm init` state. This is a destructive, irreversible operation.

### What it destroys

| Resource | Path / Location |
|----------|----------------|
| Vault file | `${XDG_DATA_HOME:-~/.local/share}/tsm/vault.enc` |
| Config file | `${XDG_CONFIG_HOME:-~/.config}/tsm/config.json` |
| Access log | `${XDG_DATA_HOME:-~/.local/share}/tsm/access.log` |
| Keychain entry | Service `com.tsm.vault`, Account `master-key` |
| Daemon process | Sends `daemon.shutdown`, removes socket file |

### Flow

1. `tsm reset` connects to the daemon and sends `vault.reset`
2. The daemon requires biometric authentication before proceeding (prevents an agent from resetting the vault)
3. On successful auth, the daemon:
   - Deletes the vault file
   - Deletes the config file
   - Deletes the access log
   - Removes the Keychain entry
   - Shuts itself down and removes the socket file
4. The CLI confirms destruction and advises `tsm init` to start fresh

If the daemon is not running, the CLI handles cleanup directly (still requires biometric auth via a Keychain access attempt before deleting files).

### Flags

| Flag | Behavior |
|------|----------|
| `--dry-run` | Lists what would be deleted without deleting anything |
| `--force` | Skips TUI confirmation prompt (still requires biometric auth) |

### Safety

- Biometric auth is always required — there is no `--no-auth` escape hatch
- The `--dry-run` flag makes the operation previewable
- The daemon logs the reset event before shutting down

## Non-Goals

- Cloud-hosted secret storage (use Doppler, AWS Secrets Manager, etc.)
- Cloud sync (iCloud, Dropbox, etc.) -- vault is local-only; copy manually if needed
- Team/shared vaults (this is a personal, local tool)
- Windows or Linux support in the initial release (protocol is cross-platform; daemon backends are future work)
- GUI application (terminal-native only)
- Secret rotation or lifecycle management
- Integration with CI/CD pipelines (use dedicated CI secrets for that)

## Open Questions

1. Should `tsm` support secret aliases (multiple names for one secret)?

## References

- [Command Line Interface Guidelines](https://clig.dev) -- human-focused CLI design
- [Rewrite Your CLI for AI Agents](https://justin.poehnelt.com/posts/rewrite-your-cli-for-ai-agents/) -- agent-focused CLI design
- [Google Workspace CLI (gws)](https://github.com/googleworkspace/cli) -- reference implementation for CLI + MCP + skills architecture
- `ssh-agent` -- architectural model for the daemon + socket pattern
- [draft-miller-ssh-agent](https://datatracker.ietf.org/doc/html/draft-miller-ssh-agent) -- SSH agent protocol spec (transport-agnostic design, extension mechanism, confirm constraint)
