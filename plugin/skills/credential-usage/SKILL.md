---
name: credential-usage
description: Use whenever a task needs an API key, token, password, database URL, certificate, or any other credential. That includes configuring an MCP server, calling an authenticated API with curl, running a CLI like gh/aws/openai, running psql or docker compose against a real service, filling in a .env, or when the user pastes a secret into chat or asks where to keep one. Consult it even when the user never says "secret" or "tsm". macOS with the tsm vault installed.
---

# Using credentials from the tsm vault

`tsm` is a Touch ID-gated secrets vault on this Mac. The user installed this plugin so you pull credentials from it instead of asking for them, and so you handle them the way this skill describes. `tsm list`, `tsm get`, `tsm run`, and `tsm status` are allowlisted for you. `tsm add` is yours to run when the user asks you to save a secret (see "Saving a credential"). `edit`, `remove`, `reset`, `init`, and `config` change or destroy existing entries and are the user's to run.

The first vault access in a session pops a system Touch ID dialog, and the command blocks until the user responds. That is normal. Do not kill or retry it. Later accesses inside the unlock window do not prompt.

## Workflow

1. **Look before asking.** `tsm list --json` returns names, display names, descriptions, tags, and the `confirm` flag. Never values. Match on any of those fields.
   ```bash
   tsm list --json
   # [{"name":"gh-pat","display_name":"GitHub PAT","description":"...","confirm":false,"tags":["github","git"]}]
   ```
   One match: use it. Several plausible matches: ask which. None: say so, propose a kebab-case name, and stop. Do not ask for the value while a match exists.
2. **Pick the carrier** for the tool (below). Prefer `tsm run` whenever the tool reads an environment variable.
3. **Do the task, then report the task.** The credential handling is yours to get right and not something the user needs to hear about. See "What to tell the user".

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
{
  "mcpServers": {
    "github": {
      "command": "tsm",
      "args": ["run", "--env", "GITHUB_PERSONAL_ACCESS_TOKEN=gh-pat", "--", "github-mcp-server"]
    }
  }
}
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

Entries with `"confirm": true` prompt Touch ID on every access, even inside the unlock window. The daemon presents the dialog in the user's GUI session, so it works from your non-TTY shell. A dialog that appears with no explanation is alarming, so when you are about to run a command that uses one, say so in a line first:

> Running the migration now; you'll get a Touch ID prompt for `pg-prod`.

That is the only time Touch ID belongs in your output. Do not mention it for entries that are not gated, and do not warn about prompts a command the user runs later might raise.

When there is no GUI login session (ssh without a console session, cron, CI), `tsm run` refuses with:

```
refusing to run: secret(s) require Touch ID confirmation but no biometric prompt can be presented here (no GUI login session): <name>
```

Hand the user a command to run where Touch ID is available. Dropping the gate with `tsm edit` is their decision. You can suggest it, never run it.

## Saving a credential the user shares with you

When the user pastes a credential and asks you to save, stash, store, or remember it, add it to the vault yourself. The value must not pass through a command line at any step:

1. Run `mktemp` for a 0600 path and write the raw value there with your file-editing tool. Not `echo`, not `printf`, not a heredoc; all of those put the value in argv or shell history.
2. Add it from that file, then delete the file:
   ```bash
   tsm add --name <kebab-id> --display-name "<Display Name>" --from-file /path/from/mktemp && rm /path/from/mktemp
   ```
   Pick the display name from what the user called it and the id from the display name in kebab-case. `--description` and `--tags` are optional; add them when the user gave you that context.
3. Use the entry for the rest of the task through `tsm run` or `tsm get`, exactly as if it had always been there.
4. Tell the user the name it was saved under in your tsm vault. That is the whole report.

If the user pastes a credential for a task without asking you to keep it, use it through the temp file (the path itself for a file-flag tool, `-H @<(printf ... "$(cat /path/from/mktemp)")` for curl), delete the file afterwards, and offer once, in one line, to save it to the vault.

If the user needs to supply a value you do not have (a missing entry), give them the `tsm add` line to run. Without `--from-file` it opens an interactive prompt that never touches argv.

## What to tell the user

The user trusts you to follow this skill. They do not need to be told that you did. A reply that explains the argv rule, environment scoping, what the value never touched, or which tsm subcommand you ran reads as padding at best and as a lecture at worst, and it buries the result they asked for.

- **Lead with the result of the task.** The customers, the migration output, the file you changed.
- **Name the entry in passing, in a few words, and say it came from tsm**, so the user can tell which credential was used and where it lives: "fetched with `stripe-live-sk` (tsm)", "as `app`, using the `pg-prod-password` tsm credential", "your tsm vault". Explain the choice only when there were several plausible matches, and then briefly: "your tsm vault's only GitHub entry" is enough; its description and scopes are not.
- **Do not narrate commands.** "I checked the tsm vault" rather than "I ran `tsm list --json`".
- **Do not explain the mechanics.** Nothing about argv, shell history, environment variables being scoped to the child, temp files, file descriptors, or the value never landing somewhere. Nothing about Touch ID beyond the one-line heads-up above.
- **Show a command only when the command is the deliverable**: the `.mcp.json` block you wrote, a `tsm add` for a value the user has and you do not, a `tsm run` line for something they will run themselves later.

Two examples, before and after:

> Your vault has one GitHub entry, `gh-token` ("GitHub token", classic PAT with repo + read:org), so I used that. The token itself never appears in `.mcp.json`, so the file is safe to commit, and it isn't in any argv. The first start in a session will pop a Touch ID prompt; `gh-token` isn't confirm-gated, so later starts won't prompt again.

becomes

> Added the GitHub MCP server to `.mcp.json`, using your tsm vault's only GitHub entry, `gh-token`. Restart Claude Code to pick it up.

and

> How I got it: the vault has a `stripe-live-sk` entry, so I used that rather than asking you for the key. The `-H @<(...)` form hands curl the auth header through a file descriptor, so the key never appears in the command line or shell history.

becomes

> Here are the 5 most recent customers from the live Stripe account, fetched with `stripe-live-sk` (tsm):

## Never

- Print, log, or quote a secret value in your reply. Not even a prefix.
- Write a value into `.env`, `.envrc`, a project config file, or any path that is not a `mktemp` file.
- `eval "$(tsm get x --format 'env X')"`. That plants the secret in the parent shell for its whole lifetime, which is exactly what `tsm run` exists to avoid.
- Guess at a value. If no entry matches and the user has not given you one, stop and ask.

## When tsm is not the answer

The tool owns its own OAuth flow (`gcloud auth login`, `gh auth login`). Use that; the vault adds nothing.
