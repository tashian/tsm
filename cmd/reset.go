package cmd

import (
	"fmt"
	"os"

	"tsm/internal/client"
	"tsm/internal/paths"

	"github.com/charmbracelet/huh"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

func newResetCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "reset",
		Short: "Destroy vault, config, log, and Keychain entry",
		Long: `Performs a full teardown of all tsm state. This is destructive and irreversible.
Requires biometric authentication.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			dryRun, _ := cmd.Flags().GetBool("dry-run")
			if dryRun {
				return runResetDryRun()
			}
			return withClient(func(c client.Caller) error {
				return runReset(cmd, c)
			})
		},
	}
	cmd.Flags().Bool("dry-run", false, "list what would be deleted without deleting")
	cmd.Flags().Bool("force", false, "skip confirmation prompt (still requires biometric auth)")
	return cmd
}

func runResetDryRun() error {
	items := []map[string]string{
		{"type": "file", "path": paths.VaultFile()},
		{"type": "file", "path": paths.ConfigFile()},
		{"type": "file", "path": paths.AccessLog()},
		{"type": "keychain", "path": "com.tsm.vault/master-key"},
		{"type": "socket", "path": paths.SocketPath()},
	}

	if jsonOutput() {
		return printJSON(map[string]any{"dry_run": true, "items": items})
	}

	fmt.Println("Would delete:")
	for _, item := range items {
		fmt.Printf("  [%s] %s\n", item["type"], item["path"])
	}
	return nil
}

func runReset(cmd *cobra.Command, c client.Caller) error {
	force, _ := cmd.Flags().GetBool("force")

	if !force && term.IsTerminal(int(os.Stdin.Fd())) {
		var confirmed bool
		form := huh.NewForm(
			huh.NewGroup(
				huh.NewConfirm().
					Title("Reset tsm? This destroys all secrets and cannot be undone.").
					Description("Biometric authentication will be required.").
					Value(&confirmed),
			),
		)
		if err := form.Run(); err != nil {
			return err
		}
		if !confirmed {
			fmt.Println("Cancelled.")
			return nil
		}
	}

	if err := c.Call("vault.reset", map[string]any{"client_id": clientID()}, nil); err != nil {
		return handleError(err)
	}

	if jsonOutput() {
		return printJSON(map[string]bool{"ok": true})
	}
	fmt.Println("All tsm data destroyed. Run 'tsm init' to start fresh.")
	return nil
}
