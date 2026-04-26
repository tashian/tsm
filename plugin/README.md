# tsm Claude Code plugin

Adds first-class tsm credential support to Claude Code:

- **Permission allowlist** auto-approves read-only and lifecycle `tsm` commands so the agent does not prompt on every secret read.
- **`credential-usage` skill** teaches the agent to discover credentials in the vault first and pick the safe retrieval pattern per tool category.

The `tsm` CLI auto-spawns the `tsmd` daemon on first use, so no SessionStart hook is needed — the first agent call (typically `tsm list --json`) brings it up transparently.

## Install

Inside Claude Code:

```
/plugin marketplace add tashian/tsm
/plugin install tsm@tsm
```

(`tsm@tsm` = plugin name `tsm` from marketplace name `tsm`.) Confirm with `/plugin` — it should appear under the **Installed** tab. Run `/reload-plugins` to apply.

### Local development

The marketplace is registered at the repository root (`.claude-plugin/marketplace.json`), so you can also point at a local checkout:

```
/plugin marketplace add /absolute/path/to/tsm
/plugin install tsm@tsm
```

## Requires

- `tsm` CLI installed and on `PATH` (see the top-level repo README).
- A vault initialized with `tsm init`.
- macOS with Touch ID.
