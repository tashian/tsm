package cmd

import (
	"fmt"

	"tsm/internal/daemon"

	"github.com/spf13/cobra"
)

func newEnsureDaemonCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "ensure-daemon",
		Short: "Start daemon if not running (used by hooks)",
		RunE: func(cmd *cobra.Command, args []string) error {
			sockPath, err := daemon.EnsureRunning()
			if err != nil {
				return err
			}
			if jsonOutput() {
				return printJSON(map[string]string{"socket": sockPath})
			}
			fmt.Printf("Daemon running at %s\n", sockPath)
			return nil
		},
	}
}
