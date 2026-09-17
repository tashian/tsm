---
name: credential-usage
description: Use when a task needs an API key, token, password, database URL, or other credential, or when the user pastes a credential into chat. macOS with the tsm vault installed.
---

# Using credentials from the tsm vault

When a task needs an API key, token, password, database URL, or other credential, use the local `tsm` vault before asking the user for it. The vault is biometric-gated (Touch ID) and the user has already approved the patterns below by installing this plugin.

## 1. Discover first

Run `tsm list --json` before assuming a credential is missing. Look for a name, description, or tag that matches what you need.

```bash
tsm list --json
# [{"name":"gh-pat","display_name":"GitHub PAT","description":"...","confirm":false,"tags":["github","git"]}, ...]
```

If exactly one entry matches, use it via the patterns below. If several plausibly match, ask the user which one. Only ask for the value itself when no matching secret exists.

## 2. Pattern by tool category

**The rule behind every pattern:** the secret value must never appear in any process's argument list. Anything in argv is visible in `ps` and lands in shell history. `tsm run` (env var), process substitution `<(...)` (the tool sees a `/dev/fd/N` path), and a `mktemp` file keep it out. `$(tsm get ...)` expanded inside an argument does not.

### MCP server credentials

MCP server configs in `.mcp.json` accept `command`/`args`. Wrap the server in `tsm run`:

```json
{
  "github": {
    "command": "tsm",
    "args": ["run", "--env", "GITHUB_TOKEN=gh-pat", "--", "github-mcp-server"]
  }
}
```

### Env-var CLI tools (gh, openai, anthropic, aws, etc.)

```bash
tsm run --env GITHUB_TOKEN=gh-pat -- gh pr list
tsm run --env OPENAI_API_KEY=openai-key -- openai api models.list
```

For `docker compose`, a bare `environment: [SENTRY_DSN]` entry passes the variable through from `tsm run`'s environment, which avoids `env_file:` entirely:

```bash
tsm run --env SENTRY_DSN=sentry-dsn -- docker compose up worker
```

### HTTP calls with curl

curl reads extra headers from a file with `-H @file`. In bash (the shell your Bash tool runs), `printf` is a builtin running inside the process substitution, so the token reaches curl only through a file descriptor:

```bash
curl -H @<(printf 'Authorization: Bearer %s\n' "$(tsm get gh-pat)") https://api.github.com/user
```

Do not write `curl -H "Authorization: Bearer $(tsm get gh-pat)"`. That expands the token into curl's argv.

### File-flag tools (curl --cacert, gcloud --key-file, psql PGPASSFILE)

If the tool reads the path once, process substitution keeps the secret off disk:

```bash
curl --cacert <(tsm get ca-cert) https://internal.example.com
```

If the tool re-reads the path or requires a regular file, write a `mktemp` file and delete it afterward. libpq is the common case: it rejects a `PGPASSFILE` that is not a plain 0600 file, so `<(...)` does not work for pgpass. `mktemp` creates the file with mode 0600 under the per-user `$TMPDIR`; a redirect into it, or `tsm get --to-file` for a raw value, keeps that mode:

```bash
PGPASSFILE=$(mktemp) && tsm get pg-prod --format pgpass > "$PGPASSFILE" && \
  PGPASSFILE="$PGPASSFILE" psql --no-password "service=mydb" -f migrate.sql ; rm -f "$PGPASSFILE"
```

There is no `/dev/shm` on macOS.

### Wire-format-specific tools

For tools that demand a specific wire format, use `tsm get --format` and redirect into a `mktemp` file. `--format` cannot be combined with `--to-file`; the redirect keeps the 0600 mode `mktemp` set:

```bash
tsm get aws-prod --format aws-credential-process   # AWS credential_process JSON
tsm get pg-prod  --format pgpass                   # validates the value as a pgpass row
ENVFILE=$(mktemp) && tsm get gh-pat --format "env GITHUB_TOKEN" > "$ENVFILE" && \
  docker run --env-file "$ENVFILE" some-image ; rm -f "$ENVFILE"
```

`tsm get --format` refuses to write to a TTY; always redirect the output.

### Tools that write their own env or config file

Some tools persist their environment to a fixed project-local path on startup (a test harness that dumps `.env.test`, a script that writes `.env` from `process.env`). If the tool you are launching does this, tell the user before launching it, and delete that file when the process exits.

## 3. Confirm-gated secrets

Secrets flagged `"confirm": true` in `tsm list --json` trigger a fresh Touch ID prompt on every access, even when the vault is already unlocked. **Check this flag during discovery (§1).**

The prompt is a system dialog presented by the tsm daemon in the user's GUI login session, so it works from a non-TTY shell like yours. **Warn the user before you trigger it**, otherwise a Touch ID dialog pops up unexplained:

> "I'm about to start the server with `anthropic-api-key`, which is confirm-gated — you'll get a Touch ID prompt to approve. For a long-running process it's a one-time cost at startup."
> ```bash
> tsm run --env ANTHROPIC_API_KEY=anthropic-api-key -- node server.js
> ```

`tsm run` refuses a confirm-gated secret only when no GUI login session exists (CI, cron, ssh without a console session):

```
refusing to run: secret(s) require Touch ID confirmation but no biometric prompt can be presented here (no GUI login session): <name>
```

If you hit that, hand the user a command to run where Touch ID is available, or **suggest** they drop confirm mode with `tsm edit <name>`. Never run `tsm edit` yourself (§4); dropping a Touch ID gate is the user's call.

## 4. Never

- **Never** echo, print, log, or include a secret value in your output to the user.
- **Never** write secrets to `.env`, `.envrc`, project-local config files, or any path other than a `mktemp` file. Delete the `mktemp` file when the command finishes.
- **Never** put a secret value in a command argument: `--token X`, `-H "Bearer X"`, `--value X` (`tsm add --value` does not exist for this reason). Argument values appear in `ps` and shell history.
- **Never** run `tsm add`, `tsm edit`, `tsm remove`, `tsm reset`, `tsm init`, or `tsm config set`. These mutations are user-driven. When the user wants to save a credential they shared with you, hand off with a one-liner that keeps the value off the shell command line and out of shell history. Pick whichever fits:
  - **Clipboard** (smoothest — user copies the value from chat, then runs):
    ```bash
    pbpaste | tsm add --no-input --name <kebab-id> --display-name "<Display Name>"
    ```
  - **File** (for multi-line values like JSON blobs, or a value you already wrote to a `mktemp` file — see below):
    ```bash
    tsm add --name <kebab-id> --display-name "<Display Name>" --from-file /path/to/tmpfile && rm /path/to/tmpfile
    ```

  Do not suggest a heredoc — heredocs go in shell history. After the secret is saved, remind the user the chat transcript still has the value, so rotation may be worth considering.
- **Never** use `eval $(tsm get ... --format env)`. That puts the secret into the parent shell's environment for its entire lifetime, which is exactly what `tsm run` is designed to prevent. Use `tsm run` for env-var injection.

## When tsm doesn't apply

- The user pastes a credential inline in chat — do not paste it into a shell command. Run `mktemp` to get a 0600 path and write the raw value there with your file-editing tool (not `echo` or a heredoc). Use that file in place of `tsm get`, for example `curl -H @<(printf 'Authorization: Bearer %s\n' "$(cat "$F")") …`, or pass it directly to a file-flag tool. Then offer the `--from-file` handoff in §4 on that same path so the user doesn't retype it. Delete the file once it is saved or no longer needed.
- The tool uses local OAuth that owns its own token lifecycle (gcloud user-OAuth, GitHub CLI's `gh auth login` flow). Use the tool's native auth; tsm doesn't help here.
- The vault is empty or no relevant secret exists — tell the user, suggest a name and `tsm add`, and stop there.
