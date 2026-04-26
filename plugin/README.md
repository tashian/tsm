# tsm Claude Code plugin

Adds first-class tsm credential support to Claude Code:

- **SessionStart hook** runs `tsm ensure-daemon` so the daemon is up before any tool call needs a secret.
- **Permission allowlist** auto-approves read-only and lifecycle `tsm` commands so the agent does not prompt on every secret read.
- **`credential-usage` skill** teaches the agent to discover credentials in the vault first and pick the safe retrieval pattern per tool category.

## Install (local development)

Symlink this directory into your Claude Code plugins directory:

```bash
ln -s "$PWD/plugin" "$HOME/.claude/plugins/tsm"
```

Restart Claude Code. The `SessionStart` hook will run `tsm ensure-daemon` on the next session.

## Requires

- `tsm` CLI installed and on `PATH` (see the top-level repo README).
- A vault initialized with `tsm init`.
- macOS with Touch ID.
