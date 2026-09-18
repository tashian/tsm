---
name: credential-usage
description: Use whenever a task needs an API key, token, password, database URL, certificate, or any other credential. That includes configuring an MCP server, calling an authenticated API with curl, running gh/aws/openai, running psql or docker compose against a real service, filling in a .env, or when the user pastes a secret into chat or asks where to keep one. Consult it even when the user never says "secret" or "tsm". macOS with the tsm vault installed.
---

# Using credentials from the tsm vault

`tsm` is a Touch ID-gated secrets vault on this Mac. The user installed this plugin so you pull credentials from it instead of asking for them. `tsm list`, `tsm get`, `tsm run`, and `tsm status` are allowlisted for you; every other subcommand (`add`, `edit`, `remove`, `reset`, `init`, `config set`) changes the vault and is the user's to run. The first vault access in a session blocks on a system Touch ID dialog until the user responds. Do not kill or retry it.

## Workflow

1. **Look before asking.** `tsm list --json` returns names, display names, descriptions, tags, and the `confirm` flag, never values. Match on any of them. One match: use it. Several plausible: ask which. None: say so, propose a kebab-case name, and stop. Do not ask for a value while a match exists.
2. **Pick the carrier** for the tool (below). Prefer `tsm run` whenever the tool reads an environment variable.
3. **Do the task, then report the task**, not the credential handling (see "What to tell the user").

## The one rule: the value never lands in an argument list

Anything in a process's argv is visible in `ps` to every user on the machine and lands in shell history. So the value travels by environment variable, file descriptor, or 0600 temp file, never as part of a command line. `$(tsm get x)` inside a flag value breaks the rule even though it looks tidy, and `eval "$(tsm get x --format 'env X')"` plants it in the parent shell for its whole lifetime.

Three carriers that respect it:

- **`tsm run --env VAR=name -- cmd`** (`--env` repeats) sets VAR in the child only; gone when the child exits.
- **`<(tsm get name)`** hands the tool a `/dev/fd/N` path; the value never touches disk. Works when the tool reads the path once. Your Bash tool runs bash, so the syntax is available.
- **`mktemp`** gives a 0600 file under the per-user `$TMPDIR` (there is no `/dev/shm` on macOS). Redirect into it and `rm` it when done.

## Patterns by tool type

**Anything that reads an env var** (gh, aws, openai, anthropic, PGPASSWORD, most SDKs):

```bash
tsm run --env GITHUB_TOKEN=gh-pat -- gh pr list
tsm run --env PGPASSWORD=pg-prod-password -- psql -h db.example.com -U app mydb -f migrate.sql
```

**MCP servers in `.mcp.json`**: wrap the server command so it inherits the credential at startup.

```json
{ "mcpServers": { "github": {
    "command": "tsm",
    "args": ["run", "--env", "GITHUB_PERSONAL_ACCESS_TOKEN=gh-pat", "--", "github-mcp-server"] } } }
```

**docker compose**: a bare key under `environment:` (`environment: [SENTRY_DSN]`) passes the variable through from the parent, so `tsm run --env SENTRY_DSN=sentry-dsn -- docker compose up worker` needs no `env_file:`. Plain `docker run` has no pass-through: `F=$(mktemp) && tsm get gh-pat --format "env GITHUB_TOKEN" > "$F" && docker run --env-file "$F" img; rm -f "$F"`.

**curl** reads extra headers from a file with `-H @file`. `printf` is a bash builtin, so the header line is assembled inside the shell and reaches curl only through a file descriptor:

```bash
curl -H @<(printf 'Authorization: Bearer %s\n' "$(tsm get gh-pat)") https://api.github.com/user
```

`curl -H "Authorization: Bearer $(tsm get gh-pat)"` looks equivalent and puts the token in curl's argv.

**Tools that take a file path** (`--cacert`, `--key-file`): `<(tsm get ca-cert)` when the path is read once; `mktemp` when the tool re-reads it or insists on a regular file. libpq is the usual case: it ignores a `PGPASSFILE` that is not a plain 0600 file, so `tsm get pg-prod --format pgpass > "$F"` into a `mktemp` path, then `PGPASSFILE="$F" psql --no-password …`. The `pgpass` formatter expects the stored value to already be a `host:port:db:user:password` row; if the vault holds only the password, use `PGPASSWORD` with `tsm run` instead.

**`tsm get --format`** offers `env VAR`, `pgpass`, and `aws-credential-process`. It refuses a TTY and cannot be combined with `--to-file`, so redirect into a `mktemp` file. AWS is the exception: `credential_process = tsm get aws-prod --format aws-credential-process` under a profile in `~/.aws/config`, and the CLI runs it itself.

**Tools that write their own env file** on startup (a test harness dumping `.env.test`): say so before launching, and delete that file when the process exits.

## Confirm-gated secrets

Entries with `"confirm": true` prompt Touch ID on every access, even inside the unlock window; the dialog appears in the user's GUI session, so it works from your non-TTY shell. An unexplained dialog is alarming, so say so in one line right before the command: "Running the migration now; you'll get a Touch ID prompt for `pg-prod`." That is the only time Touch ID belongs in your output.

With no GUI login session (ssh without a console session, cron, CI), `tsm run` refuses and names the secret. Hand the user a command to run where Touch ID is available; dropping the gate with `tsm edit` is their call.

## A credential the user pastes into chat

Use it for the task in hand, then hand off the save. The value must not pass through a command line at any step:

1. `mktemp` a 0600 path and write the raw value there with your file-editing tool. Not `echo`, `printf`, or a heredoc; those put it in argv or shell history.
2. Use that file wherever you would have used `tsm get` (`"$(cat "$F")"` in the curl form, or the path itself for a file-flag tool).
3. Give the user one command that saves it, with the real path filled in, and mention that the transcript still holds the value, so rotating it is worth considering:
   ```bash
   tsm add --name <kebab-id> --display-name "<Display Name>" --from-file /path/from/mktemp && rm /path/from/mktemp
   ```
   (`pbpaste | tsm add --no-input --name <kebab-id> --display-name "<Display Name>"` if they would rather copy it from chat.)

For a missing entry whose value you do not have, give the user a `tsm add --name <kebab-id> --display-name "…"` line; without `--from-file` it prompts interactively and never touches argv.

## What to tell the user

The user trusts you to follow this skill and does not need to be told that you did. Explaining the argv rule, environment scoping, or what the value never touched reads as a lecture and buries the result they asked for.

- **Lead with the result of the task**: the customers, the migration output, the file you changed.
- **Name the entry in passing and say it came from tsm**: "fetched with `stripe-live-sk` (tsm)", "using the `pg-prod-password` tsm credential". Explain the choice only when several entries plausibly matched, and briefly: "your tsm vault's only GitHub entry" is enough.
- **Do not narrate commands or mechanics.** "I checked the tsm vault", not "I ran `tsm list --json`". Nothing about argv, shell history, child environments, temp files, or file descriptors; nothing about Touch ID beyond the one-line heads-up above.
- **Show a command only when it is the deliverable**: the `.mcp.json` block you wrote, a `tsm add` for a value you do not have, a `tsm run` line they will run themselves later.

Not "Your vault has one GitHub entry, `gh-token` (classic PAT with repo + read:org), so I used that. The token never appears in `.mcp.json` or any argv. The first start will pop a Touch ID prompt; later starts won't." but "Added the GitHub MCP server to `.mcp.json`, using your tsm vault's only GitHub entry, `gh-token`. Restart Claude Code to pick it up."

## Never

- Print, log, or quote a secret value in your reply. Not even a prefix.
- Write a value into `.env`, `.envrc`, a project config file, or any path that is not a `mktemp` file.

## When tsm is not the answer

The tool owns its own OAuth flow (`gcloud auth login`, `gh auth login`). Use that; the vault adds nothing.
