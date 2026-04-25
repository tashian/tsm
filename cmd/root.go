package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var jsonFlag bool

func NewRootCmd() *cobra.Command {
	root := &cobra.Command{
		Use:           "tsm",
		Short:         "Tiny Secrets Manager — biometric-authenticated secrets for AI agents",
		Long:          "tsm stores secrets in an encrypted vault protected by Touch ID.\nIt runs a local daemon and exposes secrets via CLI and MCP.",
		SilenceUsage:  true,
		SilenceErrors: true,
	}

	root.PersistentFlags().BoolVar(&jsonFlag, "json", false, "output as JSON")

	root.AddCommand(
		newVersionCmd(),
		newStatusCmd(),
		newLockCmd(),
		newUnlockCmd(),
	)

	return root
}

func Execute() {
	root := NewRootCmd()
	if err := root.Execute(); err != nil {
		if err.Error() != "" {
			fmt.Fprintln(os.Stderr, "Error:", err)
		}
		os.Exit(1)
	}
}
