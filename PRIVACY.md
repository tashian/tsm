# Privacy policy

This policy applies to the `tsm` CLI, the `tsmd` daemon, and the tsm plugin for Claude Code.

## Summary

tsm keeps all data on your Mac. tsm does not send data to the developer or to other parties. tsm does not collect telemetry or analytics.

## Data that tsm stores

tsm stores these items on your Mac only:

- **The vault.** The vault contains the secrets that you add, with their names, descriptions, and tags. tsm encrypts the vault and keeps it at `~/.local/share/tsm/vault.enc`.
- **The master key.** tsm keeps the key that decrypts the vault in the macOS Keychain.
- **The access log.** For each vault operation, tsm writes the time, the operation, the secret name, the result, and the client process to `~/.local/share/tsm/access.log`. The access log does not contain secret values.
- **The daemon log.** `tsmd` writes diagnostic messages to `~/.local/share/tsm/tsmd.log`. The daemon log does not contain secret values.

If you set `XDG_DATA_HOME`, tsm uses that directory instead of `~/.local/share`.

## Network connections

The `tsm` CLI and the `tsmd` daemon do not make network connections. They communicate with each other through a Unix socket on your Mac.

## The Claude Code plugin

The plugin contains one skill and a permission list. The plugin does not contain code that runs.

The skill tells Claude Code how to get a secret from tsm and give it to a tool, for example `curl`, `gh`, or `psql`. That tool can then send the secret to its server. tsm does not control what that tool sends. You approve each first access to the vault in a session with Touch ID.

The skill tells Claude not to put secret values in the conversation. Data that you put in a Claude conversation is subject to Anthropic's privacy policy.

## Data retention

The data stays on your Mac until you delete it. To delete all tsm data, delete the `~/.local/share/tsm` directory and the `com.tsm.vault` items in the macOS Keychain.

## Children

tsm is not intended for persons under 18.

## Changes

Changes to this policy are recorded in the Git history of this file.

## Contact

For questions or security problems, open an issue at https://github.com/tashian/tsm/issues.
