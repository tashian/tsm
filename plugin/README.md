# tsm Claude Code plugin

> **Requirements:** Claude Code on macOS (Apple Silicon) with Touch ID, and the `tsm` CLI. Install the CLI first with `npm install -g @tashian/tsm`, then run `tsm init`. The plugin does not work in Cowork or the Claude apps, or on Linux or Windows.

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

## Credits

The plugin icon uses the `fingerprint` glyph from [Material Design Icons](https://github.com/google/material-design-icons) by Google, under the Apache License 2.0.
