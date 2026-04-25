package cmd

import (
	"fmt"
	"os"

	"tsm/internal/client"

	"github.com/spf13/cobra"
	"golang.org/x/term"
)

func newGetCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "get <name>",
		Short: "Retrieve a secret value",
		Long: `Retrieve a secret by name.

Default:    JSON to stdout    {"name": "...", "value": "..."}
--raw:      Raw value only    (refuses if stdout is a TTY)
--to-file:  Write to file     (mode 0600, raw value, no newline)`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return withUnlockedClient(func(c client.Caller) error {
				return runGet(cmd, c, args[0])
			})
		},
	}
	cmd.Flags().Bool("raw", false, "output raw secret value (no JSON, no newline)")
	cmd.Flags().String("to-file", "", "write secret value to file (mode 0600)")
	return cmd
}

func runGet(cmd *cobra.Command, c client.Caller, name string) error {
	raw, _ := cmd.Flags().GetBool("raw")
	toFile, _ := cmd.Flags().GetString("to-file")

	var secret struct {
		Name  string `json:"name"`
		Value string `json:"value"`
	}
	if err := c.Call("vault.get", map[string]any{"name": name, "client_id": clientID()}, &secret); err != nil {
		return handleError(err)
	}

	if toFile != "" {
		if err := os.WriteFile(toFile, []byte(secret.Value), 0o600); err != nil {
			return fmt.Errorf("write to file: %w", err)
		}
		if !jsonOutput() {
			fmt.Printf("Secret written to %s\n", toFile)
		}
		return nil
	}

	if raw {
		if term.IsTerminal(int(os.Stdout.Fd())) {
			return fmt.Errorf("refusing to write secret to terminal in --raw mode\nPipe to a command or redirect: tsm get %s --raw | some-tool", name)
		}
		fmt.Print(secret.Value)
		return nil
	}

	return printJSON(secret)
}
