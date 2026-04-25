package cmd

import (
	"fmt"

	"tsm/internal/client"

	"github.com/spf13/cobra"
)

func newStatusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show vault state, TTL remaining, daemon status",
		RunE: func(cmd *cobra.Command, args []string) error {
			return withClient(func(c client.Caller) error {
				return runStatus(c)
			})
		},
	}
}

func runStatus(c client.Caller) error {
	var status struct {
		Locked              bool `json:"locked"`
		TTLRemainingSeconds *int `json:"ttl_remaining_seconds"`
		SecretCount         int  `json:"secret_count"`
	}
	if err := c.Call("vault.status", nil, &status); err != nil {
		return handleError(err)
	}

	if jsonOutput() {
		return printJSON(status)
	}

	if status.Locked {
		fmt.Println("Vault: locked")
	} else {
		fmt.Println("Vault: unlocked")
		if status.TTLRemainingSeconds != nil {
			hours := *status.TTLRemainingSeconds / 3600
			minutes := (*status.TTLRemainingSeconds % 3600) / 60
			fmt.Printf("TTL remaining: %dh %dm\n", hours, minutes)
		}
	}
	fmt.Printf("Secrets: %d\n", status.SecretCount)
	return nil
}
