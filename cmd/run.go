package cmd

import (
	"fmt"
	"os"
	"os/exec"
	"path"
	"strings"

	"tsm/internal/client"
	"tsm/internal/runspec"

	"github.com/spf13/cobra"
	"golang.org/x/sys/unix"
)

// runnerFunc replaces the current process with the given target. In
// production, this is execveRunner (which uses unix.Exec and never returns
// on success). In tests, a fake records the would-be invocation.
//
// addedEnv contains only the VAR=value pairs that tsm run added; the full
// environment (current env + added) is what the production runner passes to
// the child via execve.
type runnerFunc func(path string, argv, addedEnv []string) error

// runOptions captures all inputs for runWith. Extracted for testability.
type runOptions struct {
	Envs     []string // raw --env flag values, in order
	Argv     []string // target command + args
	Runner   runnerFunc
	LookPath func(string) (string, error)
}

// runSecretMeta is the minimum we need from vault.list to know if a secret is
// confirm-gated before we try to use it.
type runSecretMeta struct {
	Name    string `json:"name"`
	Confirm bool   `json:"confirm"`
}

func newRunCmd() *cobra.Command {
	var envs []string
	cmd := &cobra.Command{
		Use:   "run --env VAR=secret [--env ...] -- <command> [args...]",
		Short: "Run a command with secrets injected as environment variables",
		Long: `Run a target command with one or more secrets bound to environment
variables for the duration of that subprocess.

The mapping is caller-side: --env VAR=secret-name binds the value of the
named tsm secret to environment variable VAR in the child process. The
parent shell is unaffected; the env var is gone when the child exits.

Use this for tools that read credentials from environment variables
(gh GITHUB_TOKEN, AWS_ACCESS_KEY_ID, MCP servers in .mcp.json, etc.).
For tools that read from files, use 'tsm get --to-file' or process
substitution: <(tsm get NAME).

Examples:
  tsm run --env GITHUB_TOKEN=gh-pat -- gh pr list
  tsm run --env A=key-a --env B=key-b -- ./deploy.sh prod`,
		DisableFlagsInUseLine: true,
		Args:                  cobra.MinimumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return withClient(func(c client.Caller) error {
				return runWith(c, runOptions{
					Envs:     envs,
					Argv:     args,
					Runner:   execveRunner,
					LookPath: exec.LookPath,
				})
			})
		},
	}
	cmd.Flags().StringArrayVar(&envs, "env", nil, "bind a secret to an env var (VAR=secret-name); repeatable")
	return cmd
}

func runWith(c client.Caller, opts runOptions) error {
	if len(opts.Argv) == 0 {
		return fmt.Errorf("missing target command (usage: tsm run --env VAR=secret -- <command> [args...])")
	}

	mappings, err := runspec.Parse(opts.Envs)
	if err != nil {
		return err
	}

	// Resolve target before any daemon calls — fail fast on PATH errors so the
	// user doesn't authenticate just to hit "not found".
	targetPath, err := opts.LookPath(opts.Argv[0])
	if err != nil {
		return fmt.Errorf("command %q not found in PATH", opts.Argv[0])
	}

	// Unlock vault (Touch ID once, upfront) before any vault.get.
	if err := c.Call("vault.unlock", nil, nil); err != nil {
		return handleError(err)
	}

	// A confirm-gated secret triggers a Touch ID prompt presented by the
	// daemon. The daemon can present that prompt whenever it lives in the
	// user's GUI session, regardless of how this CLI's stdin is wired — so we
	// gate on the daemon's biometric presentability (auth.can_confirm), not on
	// whether our own stdin is a TTY. This lets background/non-TTY callers
	// (e.g. an agent's Bash tool) use confirm-gated secrets, while still
	// refusing cleanly in truly headless contexts with no GUI login session,
	// rather than triggering a prompt nobody can see.
	var metas []runSecretMeta
	if err := c.Call("vault.list", nil, &metas); err != nil {
		return handleError(err)
	}
	needed := map[string]bool{}
	for _, m := range mappings {
		needed[m.Secret] = true
	}
	var confirmSecrets []string
	for _, m := range metas {
		if needed[m.Name] && m.Confirm {
			confirmSecrets = append(confirmSecrets, m.Name)
		}
	}
	if len(confirmSecrets) > 0 {
		var resp struct {
			CanConfirm bool `json:"can_confirm"`
		}
		if err := c.Call("auth.can_confirm", nil, &resp); err != nil {
			return handleError(err)
		}
		if !resp.CanConfirm {
			return fmt.Errorf("refusing to run: secret(s) require Touch ID confirmation but no biometric prompt can be presented here (no GUI login session): %s\nRun from a session where Touch ID is available, or change the secret's confirm setting via 'tsm edit'", strings.Join(confirmSecrets, ", "))
		}
	}

	// Resolve secrets, deduplicated by secret name.
	values := map[string]string{} // secret name -> value
	for _, name := range runspec.UniqueSecrets(mappings) {
		var s struct {
			Name  string `json:"name"`
			Value string `json:"value"`
		}
		params := map[string]any{
			"name":      name,
			"client_id": runClientID(path.Base(targetPath)),
		}
		if err := c.Call("vault.get", params, &s); err != nil {
			return handleError(err)
		}
		values[name] = s.Value
	}

	// Build the added-env slice in mapping order.
	addedEnv := make([]string, 0, len(mappings))
	for _, m := range mappings {
		addedEnv = append(addedEnv, m.Var+"="+values[m.Secret])
	}

	return opts.Runner(targetPath, opts.Argv, addedEnv)
}

// execveRunner is the production runnerFunc. It calls unix.Exec, which
// replaces the current process; on success it does not return.
func execveRunner(path string, argv, addedEnv []string) error {
	full := append(os.Environ(), addedEnv...)
	return unix.Exec(path, argv, full)
}

// runClientID returns the client_id used in vault.get audit log entries
// for tsm run invocations.
func runClientID(targetBasename string) string {
	return fmt.Sprintf("tsm-run/pid:%d/%s", os.Getpid(), targetBasename)
}
