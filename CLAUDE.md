# tsm — Notes for Claude

`tsm` is a Touch-ID-gated secrets manager for macOS. Two halves in one repo:

- **Go CLI** (`tsm`) at the repo root — user-facing commands and agent integration.
- **Swift daemon** (`tsmd`) in `tsmd/` — owns the encrypted vault, Keychain, Touch ID, audit log.

They communicate via newline-delimited JSON-RPC 2.0 over a Unix socket. The CLI auto-spawns the daemon on first use.

## Layout

```
go.mod, main.go        # Go CLI entry
cmd/                   # cobra subcommands (one file per command)
internal/
  client/              # JSON-RPC Unix socket client + Caller interface
  daemon/              # tsmd lifecycle (spawn, wait-for-socket)
  jsonrpc/             # JSON-RPC 2.0 types
  normalize/           # Kebab() — derives ids from display names
  paths/               # XDG path resolution
tsmd/                  # SwiftPM package (the daemon)
  Sources/tsmd/        # one .swift file per concern
  Tests/tsmdTests/     # XCTest, ~83 tests
docs/plans/            # design + implementation plans (read these first)
```

## Build & test

```bash
# Daemon (Swift, run from tsmd/)
cd tsmd && swift test
cd tsmd && swift build -c release
cp tsmd/.build/release/tsmd ~/.local/bin/tsmd

# CLI (Go, run from repo root)
go test ./...
go build -o ~/.local/bin/tsm .

# Stop a running daemon before reinstalling so pgrep + kill, e.g.:
pgrep -fl "/.local/bin/tsmd" | awk '{print $1}' | xargs -r kill
```

The daemon must be ad-hoc signed (Apple Silicon requirement). `swift build` does this automatically. Do **not** run `codesign --remove-signature` on the binary.

## Architecture

### Caller interface
Commands depend on `client.Caller` (interface), not `*DaemonClient` (concrete). Tests inject a mock. Real CLI uses `withClient` / `withUnlockedClient` helpers in `cmd/helpers.go` to dial the socket and run the command body.

### Pre-flight unlock pattern
`withUnlockedClient` calls `vault.unlock` before the command body runs. This triggers Touch ID **before** any TUI form opens, so the user doesn't fill out a long form just to be told the vault is locked. `vault.unlock` is a no-op when already unlocked, so commands inside the TTL window incur no extra prompt.

Use `withUnlockedClient` for `add`, `edit`, `get`, `list`, `remove`. Use plain `withClient` for `status`, `lock`, `unlock`, `init`, `ensure-daemon`.

### Touch ID enforcement
The Keychain item that stores the master key is **not** gated with `.biometryCurrentSet`. That flag requires the `keychain-access-groups` entitlement, which AMFI only honors with Developer ID signing. Touch ID is enforced one layer up by `Auth.authenticate` (`tsmd/Sources/tsmd/Auth.swift`) using `LAContext` before every sensitive operation. Don't reintroduce `.biometryCurrentSet` without solving signing first.

### Display name vs id
Each secret has two name fields:

- `name` — kebab-case id, validated `^[a-zA-Z0-9_-]{1,128}$`. Used for `tsm get`, env vars, audit logs, MCP, JSON keys. **Primary key.**
- `display_name` — free-text cosmetic label (≤256 chars, no control chars). Shown in `tsm list` only.

The CLI's `normalize.Kebab(s)` derives an id from a display name. `tsm add` prompts for the display name and shows a live "stored as: …" preview via `huh.DescriptionFunc`. Inline `huh.Validate` runs `Kebab` so the user gets feedback before tabbing forward.

### Vault file format
Backward-compatible JSON. `Secret.displayName` has a custom decoder defaulting to `""` for vaults written before the field existed. Don't bump the envelope `version` field unless the format actually changes incompatibly.

## Conventions

- **TDD on the daemon side.** New tsmd features get tests in `Tests/tsmdTests/` first. CLI tests are lighter (smoke + table-driven for pure helpers).
- **No `--value` flag on `tsm add`.** Secrets must come from TUI, stdin, or `--from-file`. Flag values would leak into shell history and `/proc/<pid>/cmdline`.
- **JSON-RPC keys are snake_case** (`display_name`, `ttl_remaining_seconds`). Swift uses `CodingKeys` to map; Go uses struct tags.
- **One responsibility per file.** Each `cmd/*.go` and `tsmd/Sources/tsmd/*.swift` does one thing.
- **Frequent commits.** Each task in the plans is one commit. Commit messages use Conventional Commits (`feat(tsm):`, `feat(tsmd):`, `fix(tsmd):`, `docs(plans):`, etc.).
- **Plugin skill stays in sync with the CLI.** PRs that change `tsm` flags, command names, or output shapes must update `plugin/skills/credential-usage/SKILL.md` in the same commit. The skill is what the agent reads to figure out how to use tsm; stale skill text is worse than no skill.

## Plans (read before making non-trivial changes)

- `docs/plans/2026-03-08-tsm-design.md` — overall design spec, threat model, MCP interface.
- `docs/plans/2026-03-21-tsmd-implementation.md` — daemon plan; **Addendum** at the bottom covers the `display_name` field.
- `docs/plans/2026-03-22-tsm-cli-implementation.md` — CLI plan; **Addendum** covers display-name UX, kebab-case helper, and huh validation. Also has a "Known Gaps & Daemon Dependencies" section worth scanning.
- `docs/plans/2026-04-25-tsm-agent-integration-design.md` — Plan 3 design (agent integration via `tsm run`, `tsm get --format`, and the Claude Code plugin). Drops the previously-planned `tsm mcp` and `tsm schema` in favor of the existing CLI surface.
- `docs/plans/2026-04-25-tsm-agent-integration-impl.md` — Plan 3 implementation tasks.

## Quick gotchas

- **TTL config lives only in the daemon vault.** `tsm config set ttl 30m` calls the `vault.config.set` RPC, which re-encrypts and persists the embedded `ttl_seconds`. There is no CLI-side TTL value. Changes apply on the next operation that consults TTL (effectively immediately). The CLI accepts and prints Go duration strings (`30m`, `1h30m`); the wire/storage key remains `ttl_seconds`.
- **Vault is per-session unlocked.** The daemon tracks unlock state in a `[pid_t: Date]` map keyed by the connecting peer's POSIX session id (resolved via `LOCAL_PEERPID` + `getsid`). Each session unlocks independently; locking one session doesn't disturb others. The master key is zeroed when the last session is removed. Auto-lock fires on screen lock and system sleep via `SystemEvents`.
- **`vault.unlock` with passphrase doesn't re-store the key.** Recovery on a new device decrypts but doesn't update the Keychain entry yet (see Plan 2 Known Gaps #1).
- **No `tsm daemon stop` command.** The only graceful daemon stop today is SIGTERM. `tsm reset` destroys state; SIGTERM just stops the process.
- **`tsm get` to a TTY is rejected.** Default output is the raw value with no framing; the command refuses to write secret values to a terminal — pipe, redirect, or use `--to-file`.
