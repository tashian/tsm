package cmd

import (
	"fmt"
	"os"

	"tsm/internal/client"

	"github.com/charmbracelet/huh"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

func newRemoveCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "remove <name>",
		Aliases: []string{"rm"},
		Short:   "Remove a secret from the vault",
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return withClient(func(c client.Caller) error {
				return runRemove(cmd, c, args[0])
			})
		},
	}
	cmd.Flags().Bool("force", false, "skip confirmation prompt")
	return cmd
}

func runRemove(cmd *cobra.Command, c client.Caller, name string) error {
	force, _ := cmd.Flags().GetBool("force")

	if !force && term.IsTerminal(int(os.Stdin.Fd())) {
		var confirmed bool
		form := huh.NewForm(
			huh.NewGroup(
				huh.NewConfirm().
					Title(fmt.Sprintf("Remove secret '%s'?", name)).
					Description("This cannot be undone.").
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

	if err := c.Call("vault.remove", map[string]any{"name": name, "client_id": clientID()}, nil); err != nil {
		return handleError(err)
	}

	if jsonOutput() {
		return printJSON(map[string]bool{"ok": true})
	}
	fmt.Printf("Secret '%s' removed.\n", name)
	return nil
}
