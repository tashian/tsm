package cmd

import (
	"bufio"
	"fmt"
	"os"
	"strings"

	"tsm/internal/client"

	"github.com/charmbracelet/huh"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

func newAddCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "add",
		Short: "Add a secret to the vault",
		Long: `Add a secret interactively via TUI, or non-interactively via flags and stdin.

Interactive:  tsm add
Piped:        echo "secret_value" | tsm add --name foo --no-input
From file:    tsm add --name foo --from-file /path/to/key`,
		RunE: func(cmd *cobra.Command, args []string) error {
			return withClient(func(c client.Caller) error {
				return runAdd(cmd, c)
			})
		},
	}
	cmd.Flags().String("name", "", "secret name")
	cmd.Flags().String("description", "", "secret description")
	cmd.Flags().Bool("confirm", false, "require authentication on every access")
	cmd.Flags().StringSlice("tags", nil, "tags (comma-separated)")
	cmd.Flags().String("from-file", "", "read secret value from file")
	cmd.Flags().Bool("no-input", false, "non-interactive mode (read value from stdin)")
	return cmd
}

func runAdd(cmd *cobra.Command, c client.Caller) error {
	name, _ := cmd.Flags().GetString("name")
	description, _ := cmd.Flags().GetString("description")
	confirm, _ := cmd.Flags().GetBool("confirm")
	tags, _ := cmd.Flags().GetStringSlice("tags")
	fromFile, _ := cmd.Flags().GetString("from-file")
	noInput, _ := cmd.Flags().GetBool("no-input")

	var value string

	if fromFile != "" {
		data, err := os.ReadFile(fromFile)
		if err != nil {
			return fmt.Errorf("read file: %w", err)
		}
		value = strings.TrimRight(string(data), "\n")
	} else if noInput || !term.IsTerminal(int(os.Stdin.Fd())) {
		scanner := bufio.NewScanner(os.Stdin)
		if scanner.Scan() {
			value = scanner.Text()
		}
		if err := scanner.Err(); err != nil {
			return fmt.Errorf("read stdin: %w", err)
		}
	} else {
		form := huh.NewForm(
			huh.NewGroup(
				huh.NewInput().
					Title("Secret name").
					Description("Alphanumeric, underscores, hyphens. 1-128 chars.").
					Value(&name),
				huh.NewText().
					Title("Description").
					Description("What is this secret for?").
					Value(&description),
				huh.NewInput().
					Title("Secret value").
					EchoMode(huh.EchoModePassword).
					Value(&value),
				huh.NewConfirm().
					Title("Require confirmation on every access?").
					Description("Recommended for secrets with billing implications.").
					Value(&confirm),
			),
		)
		if err := form.Run(); err != nil {
			return err
		}
	}

	if name == "" {
		return fmt.Errorf("secret name is required (use --name or interactive mode)")
	}
	if value == "" {
		return fmt.Errorf("secret value is required")
	}

	params := map[string]any{
		"name":      name,
		"value":     value,
		"client_id": clientID(),
	}
	if description != "" {
		params["description"] = description
	}
	if confirm {
		params["confirm"] = true
	}
	if len(tags) > 0 {
		params["tags"] = tags
	}

	if err := c.Call("vault.add", params, nil); err != nil {
		return handleError(err)
	}

	if jsonOutput() {
		return printJSON(map[string]bool{"ok": true})
	}
	fmt.Printf("Secret '%s' added.\n", name)
	return nil
}
