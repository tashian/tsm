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
	var resp struct {
		OK                  bool `json:"ok"`
		TTLRemainingSeconds *int `json:"ttl_remaining_seconds"`
	}
	if err := c.Call("vault.unlock", nil, &resp); err != nil {
		return handleError(err)
	}
	if jsonOutput() {
		return printJSON(resp)
	}
	if resp.TTLRemainingSeconds != nil {
		hours := *resp.TTLRemainingSeconds / 3600
		minutes := (*resp.TTLRemainingSeconds % 3600) / 60
		fmt.Printf("Vault unlocked for %dh %dm.\n", hours, minutes)
	} else {
		fmt.Println("Vault unlocked.")
	}
	return nil
}
