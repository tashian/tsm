package cmd

import (
	"fmt"

	"github.com/spf13/cobra"
)

// Version is set at build time via -ldflags.
var Version = "dev"

func newVersionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print tsm version",
		Run: func(cmd *cobra.Command, args []string) {
			if jsonOutput() {
				printJSON(map[string]string{"version": Version})
				return
			}
			fmt.Printf("tsm %s\n", Version)
		},
	}
}
