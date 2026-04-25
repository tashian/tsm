package cmd

import (
	"fmt"

	"tsm/internal/client"

	"github.com/spf13/cobra"
)

func newLockCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "lock",
		Short: "Lock the vault immediately",
		RunE: func(cmd *cobra.Command, args []string) error {
			return withClient(func(c client.Caller) error {
				return runLock(c)
			})
		},
	}
}

func runLock(c client.Caller) error {
	if err := c.Call("vault.lock", nil, nil); err != nil {
		return handleError(err)
	}
	if jsonOutput() {
		return printJSON(map[string]bool{"ok": true})
	}
	fmt.Println("Vault locked.")
	return nil
}
