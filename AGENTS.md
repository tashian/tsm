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
```

## Build & test

```bash
just test                 # go test ./... + swift test (tsmd/)
just build                # both binaries → dist/bin/
cp dist/bin/tsm dist/bin/tsmd ~/.local/bin/
pgrep -fl "/.local/bin/tsmd" | awk '{print $1}' | xargs -r kill   # stop the old daemon before reinstalling
```

The daemon must be ad-hoc signed (Apple Silicon requirement). `swift build` does this automatically. Do **not** run `codesign --remove-signature` on the binary.

## Releasing

Tag-driven: `git tag -a vX.Y.Z && git push origin vX.Y.Z` triggers `.github/workflows/release.yml`. Full procedure and one-time setup are in `RELEASING.md` — read it before cutting a release. Rules that are easy to get wrong:

- Tag the merge commit on `main`, never a feature branch. Expect one `github-actions[bot]` commit on `main` after every release (plugin version bump); pull before branching.
- **Don't hand-edit versions.** `npm/*/package.json` stay `0.0.0` (workflow rewrites from the tag at publish time). `plugin/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` are bumped and committed by the workflow — that one has to land in git because `claude plugin update` only refreshes when the manifest version changes.
- **Publish order is load-bearing.** `@tashian/tsm-darwin-arm64` publishes before the wrapper `@tashian/tsm` so `optionalDependencies` resolve. Don't reorder.
- **npm Trusted Publishing needs Node 24 / npm 11.** Node 22's npm 10 silently publishes unauthenticated and 404s — don't downgrade `setup-node`.
- **Irreversible.** A published npm version can't be re-published. Confirm the version before pushing the tag.

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

- **TDD on both sides.** New features get a failing test first — Swift tests in `Tests/tsmdTests/`, Go tests as `*_test.go` next to the command or helper. The daemon already has full coverage; many CLI commands in `cmd/` were written before this convention and lack tests — backfill tests when you touch one of them.
- **No `--value` flag on `tsm add`.** Secrets must come from TUI, stdin, or `--from-file`. Flag values would leak into shell history and `/proc/<pid>/cmdline`.
- **JSON-RPC keys are snake_case** (`display_name`, `ttl_remaining_seconds`). Swift uses `CodingKeys` to map; Go uses struct tags.
- **One responsibility per file.** Each `cmd/*.go` and `tsmd/Sources/tsmd/*.swift` does one thing.
- **Frequent commits.** Commit messages use Conventional Commits (`feat(tsm):`, `feat(tsmd):`, `fix(tsmd):`, etc.).
- **Plugin skill stays in sync with the CLI.** PRs that change `tsm` flags, command names, or output shapes must update `plugin/skills/credential-usage/SKILL.md` in the same commit. The skill is what the agent reads to figure out how to use tsm; stale skill text is worse than no skill.

## Quick gotchas

- **TTL config lives only in the daemon vault.** `tsm config set ttl 30m` calls the `vault.config.set` RPC, which re-encrypts and persists the embedded `ttl_seconds`. There is no CLI-side TTL value. Changes apply on the next operation that consults TTL (effectively immediately). The CLI accepts and prints Go duration strings (`30m`, `1h30m`); the wire/storage key remains `ttl_seconds`.
- **Vault is per-session unlocked.** The daemon tracks unlock state in a `[pid_t: Date]` map keyed by a *durable* session id derived from the connecting peer (`LOCAL_PEERPID` + `getsid`, then `PeerSession.resolveDurableSessionID` walks up the session-leader chain past any `setsid()`-spawned ephemeral sessions, stopping when the next ancestor lives in sid=1). This collapses every command an agent harness like Claude Code's Bash tool spawns into one shared session, while keeping distinct terminal tabs / ssh sessions / iTerm windows isolated. Each session unlocks independently; locking one session doesn't disturb others. The master key is zeroed when the last session is removed. Auto-lock fires on screen lock and system sleep via `SystemEvents`.
- **Temp / secondary vaults.** Both halves honor `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, and `TSM_AUTH_SOCK`, and the CLI passes its environment through to the daemon it spawns. The master key's Keychain account is derived from the vault path (`MacKeychain.account(forVaultPath:)`): the default `~/.local/share/tsm/vault.enc` keeps the legacy `master-key` account so existing installs are untouched; any other path gets `master-key:<sha256 of path>`. So a throwaway vault under a temp `XDG_DATA_HOME` can be `tsm init`'d without clobbering the real vault's key. Keying is by path, so moving a non-default vault file strands its key (recover via passphrase). `tsm` has no `--vault` flag; use the env vars.
- **`vault.unlock` with passphrase doesn't re-store the key.** Recovery on a new device decrypts but doesn't update the Keychain entry yet.
- **`tsm get` to a TTY is rejected.** Default output is the raw value with no framing; the command refuses to write secret values to a terminal — pipe, redirect, or use `--to-file`.
