---
name: credential-usage
description: Use whenever a task requires an API key, token, password, or other credential. Checks the local tsm vault first; teaches safe retrieval patterns by tool category.
---

# Using credentials from the tsm vault

When a task needs an API key, token, password, database URL, or other credential, use the local `tsm` vault before asking the user for it. The vault is biometric-gated (Touch ID) and the user has already approved the patterns below by installing this plugin.

## 1. Discover first

Run `tsm list --json` before assuming a credential is missing. Look for a name, description, or tag that matches what you need.

```bash
tsm list --json
# [{"name":"gh-pat","display_name":"GitHub PAT","description":"...","confirm":false,"tags":["github","git"]}, ...]
```

If `tsm list` shows the credential, use it via one of the patterns below. Only ask the user if no matching secret exists.

## 2. Pattern by tool category

Pick the pattern that matches the consuming tool. Never fall back to a less safe pattern just because it is shorter.

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

For one-off invocations:

```bash
tsm run --env GITHUB_TOKEN=gh-pat -- gh pr list
tsm run --env OPENAI_API_KEY=openai-key -- openai api models.list
```

For one-shot value capture inside a single shell pipeline (no env-var leakage):

```bash
curl -H "Authorization: Bearer $(tsm get gh-pat --raw)" https://api.github.com/user
```

### File-flag tools (curl --cacert, psql --pgpass, gcloud --key-file)

Process substitution keeps the secret off disk entirely:

```bash
curl --cacert <(tsm get ca-cert --raw) https://internal.example.com
PGPASSFILE=<(tsm get pg-prod --format pgpass) psql --no-password "service=mydb"
```

If the tool re-reads the file after first read, write to `/dev/shm` (memory-backed on Linux, ramdisk on macOS):

```bash
KEYFILE=$(mktemp /dev/shm/key.XXXXXX) && \
  tsm get client-key --to-file "$KEYFILE" && \
  some-tool --key "$KEYFILE" ; rm -f "$KEYFILE"
```

### Wire-format-specific tools

For tools that demand a specific wire format, use `tsm get --format`:

```bash
tsm get aws-prod --format aws-credential-process       # AWS credential_process JSON
tsm get pg-prod  --format pgpass                       # pgpass row
tsm get gh-pat   --format "env GITHUB_TOKEN" > /dev/shm/envfile   # docker --env-file
```

`tsm get --format` refuses to write to a TTY; always redirect the output.

## 3. Confirm-gated secrets

Some secrets are flagged `"confirm": true` in `tsm list`. Each access triggers a Touch ID prompt, even if the vault is already unlocked. Before invoking such a secret, tell the user to expect the prompt:

> "I'm about to fetch `aws-prod`, which is confirm-gated — please approve the Touch ID prompt."

If a confirm-gated secret is needed and stdin is not a TTY (e.g., the agent is running headless), `tsm run` will refuse with a clear error. That is intended; the user must change the secret's `confirm` setting via `tsm edit` if non-interactive use is needed.

## 4. Never

- **Never** echo, print, log, or include a secret value in your output to the user.
- **Never** write secrets to `.env`, `.envrc`, project-local config files, or any path outside `/tmp` or `/dev/shm`.
- **Never** pass secrets as `--value`-style flags. (`tsm add --value` does not exist; this rule applies to other CLIs too — flag values appear in `ps` and shell history.)
- **Never** run `tsm add`, `tsm edit`, `tsm remove`, `tsm reset`, `tsm init`, or `tsm config set`. These mutations are user-driven. When the user wants to save a credential they shared with you, hand off with a one-liner that keeps the value off the shell command line and out of shell history. Pick whichever fits:
  - **Clipboard** (smoothest — user copies the value from chat, then runs):
    ```bash
    pbpaste | tsm add --no-input --name <kebab-id> --display-name "<Display Name>"
    ```
  - **File** (for multi-line values like JSON blobs — user saves to a temp file first):
    ```bash
    tsm add --name <kebab-id> --display-name "<Display Name>" --from-file /tmp/x && rm /tmp/x
    ```
  
  Do not suggest a heredoc — heredocs go in shell history. After the secret is saved, remind the user the chat transcript still has the value, so rotation may be worth considering.
- **Never** use `eval $(tsm get ... --format env)`. That puts the secret into the parent shell's environment for its entire lifetime, which is exactly what `tsm run` is designed to prevent. Use `tsm run` for env-var injection.

## When tsm doesn't apply

- The user pastes a credential inline in chat — use it for the current task, then offer to save it via the `pbpaste`/`--from-file` handoff in §4 (do not suggest bare `tsm add`, which makes them retype the value into the TUI).
- The tool uses local OAuth that owns its own token lifecycle (gcloud user-OAuth, GitHub CLI's `gh auth login` flow). Use the tool's native auth; tsm doesn't help here.
- The vault is empty or no relevant secret exists — tell the user, suggest a name and `tsm add`, and stop there.
