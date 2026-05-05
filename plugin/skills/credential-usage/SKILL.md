---
name: credential-usage
description: Use whenever a task requires an API key, token, password, or other credential, OR whenever a task surfaces naked credentials on the filesystem (e.g. auditing a repo for hardcoded secrets, sweeping `.env` files, fixing leaked tokens). Checks the local tsm vault first; teaches safe retrieval patterns by tool category; teaches safe sweep-into-vault patterns for naked credentials.
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
curl -H "Authorization: Bearer $(tsm get gh-pat)" https://api.github.com/user
```

### File-flag tools (curl --cacert, psql --pgpass, gcloud --key-file)

Process substitution keeps the secret off disk entirely:

```bash
curl --cacert <(tsm get ca-cert) https://internal.example.com
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
- **Never** run `tsm edit`, `tsm remove`, `tsm reset`, `tsm init`, or `tsm config set`. These mutations are user-driven; ask the user to run them.
- **Never** use `eval $(tsm get ... --format env)`. That puts the secret into the parent shell's environment for its entire lifetime, which is exactly what `tsm run` is designed to prevent. Use `tsm run` for env-var injection.

`tsm add` is **allowed** when sweeping naked credentials you've already discovered on disk — see §5 for the required workflow and safety guardrails. `tsm add` is the only mutation a `tsm` agent may run on its own initiative; everything else stays user-driven.

## 5. Sweeping naked credentials into the vault

When you discover a cleartext credential on the filesystem (in a `.env`, hardcoded in source, in an MCP config, in a shell history snippet) you may move it into the vault using `tsm add`. The value travels from the file into tsm and never appears in chat, in shell history, or in `ps` output.

### Workflow

1. **Check for an existing entry.** Run `tsm list --json` and look for a name, description, or tag that matches. If a matching entry exists and you can safely confirm the value matches, just rewrite the call site to use `tsm get`/`tsm run` (skip to step 5). If a matching entry exists but the value differs, surface to the user — do not silently overwrite.
2. **Choose an id and display name.** The id is kebab-case, validated `^[a-zA-Z0-9_-]{1,128}$`. Pick something specific (`openai-key-myapp`, not just `openai-key`) so future sweeps don't collide.
3. **Announce intent.** Tell the user, before running anything: which env var/file you're moving, the chosen id, and that the value will not appear in chat or shell history. Mention the Touch ID prompt.
4. **Move the value via stdin or `--from-file`.** Use one of the safe forms below.
5. **Verify, then scrub.** Confirm the entry exists with `tsm list --json` (which never includes values). Then remove/rewrite the original cleartext.
6. **Replace the call site.** Update the consumer to use `tsm get` or `tsm run` per §2.
7. **Warn about git history if applicable.** If the original file is committed to git, tell the user the value is in history and rotation is required. Do NOT run `git filter-repo`, `git filter-branch`, or BFG autonomously.

### Safe transport: stdin pipe (preferred)

`printf` is a shell builtin in bash/zsh, so the value does NOT appear in `ps` output. The Bash tool in Claude Code is `bash -c`, where `printf` is a builtin.

```bash
KEY=$(grep '^OPENAI_API_KEY=' .env | cut -d= -f2-)
printf '%s' "$KEY" | tsm add \
  --name openai-key-myapp \
  --display-name "OpenAI API Key (myapp)" \
  --description "Swept from ./.env on 2026-05-01" \
  --tags swept,openai \
  --json
unset KEY
# {"ok":true}
```

`tsm add` auto-detects piped (non-TTY) stdin, so `--no-input` is not required.

### Safe transport: --from-file

If the value is already in a file you control:

```bash
tsm add --name gcp-sa --display-name "GCP service account (myapp)" \
  --from-file ./service-account.json --json
# {"ok":true}
rm ./service-account.json
```

`tsm add --from-file` reads the file and trims a single trailing newline. Multi-line values (PEM bundles, JSON blobs) are preserved verbatim.

### Never (sweep-specific)

- **Never** pass the value as a flag. `tsm add --value sk-…` does not exist and never will. Other agents/tools that show flag values in `ps` will leak the secret.
- **Never** put the value in a positional argument. `tsm add foo sk-…` is rejected.
- **Never** use `echo` to pipe the value. `echo` is not guaranteed to be a shell builtin (notably in fish without `builtin echo`). Use `printf '%s'` in bash/zsh.
- **Never** use a heredoc (`<<EOF\nsk-…\nEOF`). Heredocs land in shell history.
- **Never** paste the value into the chat transcript at any step. The transcript is durable; the value should travel from the file to tsm without being echoed.
- **Never** write the value to an intermediate scratch file unless you `--from-file` it directly and `rm` immediately after. Don't `cat`, `head`, `tail`, or otherwise dump it to a buffer you can't clean up.
- **Never** delete the source file before `tsm list --json` confirms the new entry exists. A daemon error during `tsm add` would otherwise lose the secret.
- **Never** commit the scrubbed source file without warning the user the original value is in git history and rotation is required. Do NOT run `git filter-repo`, `git filter-branch`, or BFG autonomously.
- **Never** run a sweep silently. Always announce intent and the chosen id before invoking `tsm add`, so the user can interject.

### Worked example

**Initial state:** `./.env`
```
DATABASE_URL=postgres://localhost/myapp
OPENAI_API_KEY=sk-proj-abc123def456ghi789
PORT=3000
```

**Agent's transcript to user:**

> I noticed `OPENAI_API_KEY` is hardcoded in `./.env`. I'm going to move it into the tsm vault as `openai-key-myapp` and rewrite the call site to use `tsm run`. The value will not appear in chat or shell history. Please approve the Touch ID prompt when it appears.

```bash
# 1. Confirm no existing entry
tsm list --json | jq '.[] | select(.name=="openai-key-myapp")'
# (empty)

# 2. Read the value into a shell variable, then pipe it through printf (builtin)
KEY=$(grep '^OPENAI_API_KEY=' .env | cut -d= -f2-)
printf '%s' "$KEY" | tsm add \
  --name openai-key-myapp \
  --display-name "OpenAI API Key (myapp)" \
  --description "Swept from ./.env on 2026-05-01" \
  --tags swept,openai \
  --json
unset KEY
# {"ok":true}

# 3. Verify (without revealing the value)
tsm list --json | jq '.[] | select(.name=="openai-key-myapp") | {name,display_name,tags}'
# {"name":"openai-key-myapp","display_name":"OpenAI API Key (myapp)","tags":["swept","openai"]}

# 4. Remove the line from .env
sed -i.bak '/^OPENAI_API_KEY=/d' .env && rm .env.bak

# 5. Update the run script (or process manager) to inject via tsm run.
#    e.g. in package.json:  "start": "tsm run --env OPENAI_API_KEY=openai-key-myapp -- node server.js"
#    Or for a one-off:      tsm run --env OPENAI_API_KEY=openai-key-myapp -- node server.js
```

**Final state:** `./.env`
```
DATABASE_URL=postgres://localhost/myapp
PORT=3000
```

**Final state:** `./package.json` (excerpt)
```json
"scripts": {
  "start": "tsm run --env OPENAI_API_KEY=openai-key-myapp -- node server.js"
}
```

**Agent's closing message to user:**

> Moved `OPENAI_API_KEY` to tsm as `openai-key-myapp`. The original value was in `./.env`, which is gitignored — but please double-check `git log -S 'sk-proj-abc' -- .env` to confirm it never landed in history. If it did, rotate the key at platform.openai.com. The chat transcript above only contains the prefix `sk-proj-abc…` of the original value (which I included to identify it), so consider rotation regardless.

Tagging swept credentials with `swept` makes future audits easy:

```bash
tsm list --json | jq '.[] | select(.tags | index("swept"))'
```

## When tsm doesn't apply

- The user pastes a credential inline in chat — use it for the current task, then offer to sweep it via the §5 workflow (`printf '%s' "$VAR" | tsm add …`) so the value moves into the vault without being retyped into the TUI.
- The tool uses local OAuth that owns its own token lifecycle (gcloud user-OAuth, GitHub CLI's `gh auth login` flow). Use the tool's native auth; tsm doesn't help here.
- The vault is empty or no relevant secret exists, and you have no value to sweep — tell the user, suggest a name, and stop there.
