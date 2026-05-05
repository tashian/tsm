package cmd

import (
	"fmt"
	"io"
	"os"

	"github.com/spf13/cobra"

	"tsm/internal/client"
	"tsm/internal/paths"
)

func newDaemonCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "daemon",
		Short: "Manage the tsmd background daemon",
	}
	cmd.AddCommand(newDaemonStopCmd())
	return cmd
}

func newDaemonStopCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "stop",
		Short: "Gracefully stop the tsmd daemon",
		RunE: func(cmd *cobra.Command, args []string) error {
			// Short-circuit if the socket is dead so we don't spawn a daemon
			// just to kill it.
			if !client.IsSocketLive(paths.SocketPath()) {
				return runDaemonStop(nil, true, os.Stdout)
			}
			return withClient(func(c client.Caller) error {
				return runDaemonStop(c, false, os.Stdout)
			})
		},
	}
}

// runDaemonStop calls daemon.shutdown when the daemon is reachable, or prints
// an idempotent "not running" message when alreadyDown is true.
func runDaemonStop(c client.Caller, alreadyDown bool, stdout io.Writer) error {
	if alreadyDown {
		if jsonOutput() {
			return printJSONTo(stdout, map[string]any{
				"stopped":      false,
				"already_down": true,
			})
		}
		fmt.Fprintln(stdout, "tsmd not running.")
		return nil
	}
	if err := c.Call("daemon.shutdown", nil, nil); err != nil {
		return handleError(err)
	}
	if jsonOutput() {
		return printJSONTo(stdout, map[string]any{"stopped": true})
	}
	fmt.Fprintln(stdout, "tsmd stopped.")
	return nil
}
