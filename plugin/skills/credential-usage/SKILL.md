---
name: credential-usage
description: Use whenever a task needs an API key, token, password, database URL, certificate, or any other credential. That includes configuring an MCP server, calling an authenticated API with curl, running a CLI like gh/aws/openai, running psql or docker compose against a real service, filling in a .env, or when the user pastes a secret into chat or asks where to keep one. Consult it even when the user never says "secret" or "tsm". macOS with the tsm vault installed.
---

# Using credentials from the tsm vault

`tsm` is a Touch ID-gated secrets vault on this Mac. The user installed this plugin so you pull credentials from it instead of asking, and so you handle them the way this skill describes. `tsm list`, `tsm get`, and `tsm run` are allowlisted for you. Every other `tsm` subcommand (`add`, `edit`, `remove`, `reset`, `init`, `config set`) changes the vault and is the user's to run.

The first vault access in a session pops a system Touch ID dialog, and the command blocks until the user responds. That is normal. Do not kill or retry it. Later accesses inside the unlock window do not prompt.

## Workflow

1. **Look before asking.** `tsm list --json` returns names, display names, descriptions, tags, and the `confirm` flag. Never values. Match on any of those fields.
   ```bash
   tsm list --json
   # [{"name":"gh-pat","display_name":"GitHub PAT","description":"...","confirm":false,"tags":["github","git"]}]
   ```
   One match: use it. Several plausible matches: ask which. None: tell the user, suggest a name, and stop. Do not ask for the value unless nothing matches.
2. **Pick the delivery pattern** for the tool (below). Prefer `tsm run` whenever the tool reads an environment variable.
3. **If the entry has `"confirm": true`, warn before using it** (see "Confirm-gated secrets").

## The one rule: the value never lands in an argument list

Anything in a process's argv is visible in `ps` to every user on the machine and is written to shell history. So the value has to travel by environment variable, file descriptor, or a 0600 temp file, never as part of a command line. `$(tsm get x)` expanded inside a flag value breaks the rule even though it looks tidy.

Three carriers that respect it:

- **`tsm run --env VAR=name -- cmd`** sets VAR in the child process only. The parent shell is untouched and the variable is gone when the child exits.
- **`<(tsm get name)`** process substitution. The tool receives a `/dev/fd/N` path and the value never touches disk. Works when the tool reads the path once. Your Bash tool runs bash, so this syntax is available to you.
- **`mktemp`** gives a 0600 file under the per-user `$TMPDIR`. Redirect into it and `rm` it when done. There is no `/dev/shm` on macOS.

## Patterns by tool type

### Anything that reads an env var (gh, aws, openai, anthropic, PGPASSWORD, most SDKs)

```bash
tsm run --env GITHUB_TOKEN=gh-pat -- gh pr list
tsm run --env PGPASSWORD=pg-prod-password -- psql -h db.example.com -U app mydb -f migrate.sql
tsm run --env A=key-a --env B=key-b -- ./deploy.sh prod
```

### MCP servers in `.mcp.json`

Wrap the server command so it inherits the credential at startup:

```json
{ "github": { "command": "tsm", "args": ["run", "--env", "GITHUB_TOKEN=gh-pat", "--", "github-mcp-server"] } }
```

### docker compose and docker run

A bare key under `environment:` passes the variable through from the parent process, so `tsm run` covers compose with no `env_file:` at all:

```yaml
services:
  worker:
    environment: [SENTRY_DSN]
```
```bash
tsm run --env SENTRY_DSN=sentry-dsn -- docker compose up worker
```

Plain `docker run` has no pass-through, so generate an `--env-file` in a temp file:

```bash
F=$(mktemp) && tsm get gh-pat --format "env GITHUB_TOKEN" > "$F" && docker run --env-file "$F" some-image; rm -f "$F"
```

### curl and other HTTP clients

curl reads extra headers from a file with `-H @file`. `printf` is a bash builtin, so the header line is assembled inside the shell and reaches curl only through a file descriptor:

```bash
curl -H @<(printf 'Authorization: Bearer %s\n' "$(tsm get gh-pat)") https://api.github.com/user
```

`curl -H "Authorization: Bearer $(tsm get gh-pat)"` is the tempting version, and it puts the token in curl's argv.

### Tools that take a file path (`--cacert`, `--key-file`, `PGPASSFILE`)

If the tool reads the path once, process substitution keeps the value off disk:

```bash
curl --cacert <(tsm get ca-cert) https://internal.example.com
```

If the tool insists on a regular file, or re-reads it, use a temp file. libpq is the usual case: it ignores a `PGPASSFILE` that is not a plain 0600 file, so `<(...)` does not work for pgpass.

```bash
F=$(mktemp) && tsm get pg-prod --format pgpass > "$F" && PGPASSFILE="$F" psql --no-password "service=mydb" -f migrate.sql; rm -f "$F"
```

The `pgpass` formatter expects the stored value to already be a `host:port:db:user:password` row. If the vault holds only the password, skip the file and use `PGPASSWORD` with `tsm run` as shown above.

### Wire formats: `tsm get --format`

Built-in formatters: `env VAR`, `pgpass`, `aws-credential-process`. `--format` refuses to write to a TTY and cannot be combined with `--to-file`, so redirect into a `mktemp` file; the redirect keeps the file's 0600 mode. AWS is the exception: the CLI runs `credential_process` itself and reads stdout, so the command goes in `~/.aws/config` with no redirect:

```ini
[profile prod]
credential_process = tsm get aws-prod --format aws-credential-process
```

### Tools that write their own env file

Some tools dump their environment to a fixed project path on startup: a test harness that writes `.env.test`, a script that materializes `.env` from `process.env`. If the tool you are about to launch does this, say so before launching, and delete that file when the process exits. Otherwise the vault's protection ends the moment the tool starts.

## Confirm-gated secrets

Entries with `"confirm": true` prompt Touch ID on every access, even inside the unlock window. The daemon presents the dialog in the user's GUI session, so it works from your non-TTY shell, but a dialog that appears with no explanation is alarming. Say what you are about to do and that a prompt will appear:

> Starting the server with `anthropic-api-key`, which is confirm-gated, so you'll get one Touch ID prompt at startup.

When there is no GUI login session (ssh without a console session, cron, CI), `tsm run` refuses with:

```
refusing to run: secret(s) require Touch ID confirmation but no biometric prompt can be presented here (no GUI login session): <name>
```

Hand the user a command to run where Touch ID is available. Dropping the gate with `tsm edit` is their decision. You can suggest it, never run it.

## Saving a credential the user shares with you

When the user pastes a credential into chat, or asks you to store one, use it for the task in hand and then hand off the save. The value must not pass through a command line at any step:

1. Run `mktemp` for a 0600 path and write the raw value there with your file-editing tool. Not `echo`, not a heredoc; both put the value in argv or shell history.
2. Use that file wherever you would have used `tsm get`: `-H @<(printf 'Authorization: Bearer %s\n' "$(cat /path/from/mktemp)")` for curl, or the path itself for a file-flag tool.
3. Give the user one command that saves it, with the real temp path filled in:
   ```bash
   tsm add --name <kebab-id> --display-name "<Display Name>" --from-file /path/from/mktemp && rm /path/from/mktemp
   ```
   If they would rather copy the value from chat than trust your file:
   ```bash
   pbpaste | tsm add --no-input --name <kebab-id> --display-name "<Display Name>"
   ```
4. Delete the temp file once it is saved or no longer needed, and mention that the chat transcript still holds the value, so rotating it is worth considering.

## Never

- Print, log, or quote a secret value in your reply. Not even a prefix.
- Write a value into `.env`, `.envrc`, a project config file, or any path that is not a `mktemp` file.
- `eval "$(tsm get x --format 'env X')"`. That plants the secret in the parent shell for its whole lifetime, which is exactly what `tsm run` exists to avoid.

## When tsm is not the answer

- The tool owns its own OAuth flow (`gcloud auth login`, `gh auth login`). Use that; the vault adds nothing.
- No entry matches. Say so, propose a kebab-case name, and let the user run `tsm add`. Do not guess at a value.
