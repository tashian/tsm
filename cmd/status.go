package cmd

import (
	"fmt"
	"io"
	"os"

	"tsm/internal/client"
	"tsm/internal/paths"

	"github.com/spf13/cobra"
)

func newStatusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show vault state, TTL remaining, daemon status",
		RunE: func(cmd *cobra.Command, args []string) error {
			return withClient(func(c client.Caller) error {
				return runStatus(c, os.Stdout)
			})
		},
	}
}

func runStatus(c client.Caller, stdout io.Writer) error {
	var s struct {
		Locked              bool `json:"locked"`
		TTLRemainingSeconds *int `json:"ttl_remaining_seconds"`
		SecretCount         int  `json:"secret_count"`
	}
	if err := c.Call("vault.status", nil, &s); err != nil {
		return handleError(err)
	}

	vaultPath := paths.VaultFile()

	if jsonOutput() {
		out := map[string]any{
			"version":      Version,
			"vault_path":   vaultPath,
			"locked":       s.Locked,
			"secret_count": s.SecretCount,
		}
		if s.TTLRemainingSeconds != nil {
			out["ttl_remaining_seconds"] = *s.TTLRemainingSeconds
		}
		return printJSONTo(stdout, out)
	}

	fmt.Fprintf(stdout, "tsm %s\n", Version)
	fmt.Fprintf(stdout, "Vault file: %s\n", vaultPath)
	if s.Locked {
		fmt.Fprintln(stdout, "Vault: locked")
	} else {
		fmt.Fprintln(stdout, "Vault: unlocked")
		if s.TTLRemainingSeconds != nil {
			hours := *s.TTLRemainingSeconds / 3600
			minutes := (*s.TTLRemainingSeconds % 3600) / 60
			fmt.Fprintf(stdout, "TTL remaining: %dh %dm\n", hours, minutes)
		}
	}
	fmt.Fprintf(stdout, "Secrets: %d\n", s.SecretCount)
	return nil
}
