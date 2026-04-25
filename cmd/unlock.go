package cmd

import (
	"fmt"

	"tsm/internal/client"

	"github.com/spf13/cobra"
)

func newUnlockCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "unlock",
		Short: "Unlock the vault (triggers Touch ID)",
		RunE: func(cmd *cobra.Command, args []string) error {
			return withClient(func(c client.Caller) error {
				return runUnlock(c)
			})
		},
	}
}

func runUnlock(c client.Caller) error {
	if err := c.Call("vault.unlock", nil, nil); err != nil {
		return handleError(err)
	}
	if jsonOutput() {
		return printJSON(map[string]bool{"ok": true})
	}
	fmt.Println("Vault unlocked.")
	return nil
}
