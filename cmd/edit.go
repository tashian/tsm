package cmd

import (
	"fmt"
	"os"
	"strings"

	"tsm/internal/client"

	"github.com/charmbracelet/huh"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

func newEditCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "edit <name>",
		Short: "Modify a secret's value, description, or confirm flag",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return withClient(func(c client.Caller) error {
				return runEdit(cmd, c, args[0])
			})
		},
	}
	cmd.Flags().String("display-name", "", "new display name (empty string clears)")
	cmd.Flags().String("description", "", "new description")
	cmd.Flags().String("value", "", "not supported — use interactive mode or pipe")
	cmd.Flags().Bool("confirm", false, "set confirm flag")
	cmd.Flags().Bool("no-confirm", false, "clear confirm flag")
	cmd.Flags().StringSlice("tags", nil, "replace tags")
	cmd.Flags().Bool("no-input", false, "non-interactive mode")
	cmd.Flags().MarkHidden("value")
	return cmd
}

func runEdit(cmd *cobra.Command, c client.Caller, name string) error {
	var secrets []secretMetadata
	if err := c.Call("vault.list", nil, &secrets); err != nil {
		return handleError(err)
	}

	var current *secretMetadata
	for i := range secrets {
		if strings.EqualFold(secrets[i].Name, name) {
			current = &secrets[i]
			break
		}
	}
	if current == nil {
		return fmt.Errorf("secret '%s' not found", name)
	}

	params := map[string]any{"name": name, "client_id": clientID()}

	noInput, _ := cmd.Flags().GetBool("no-input")

	if !noInput && term.IsTerminal(int(os.Stdin.Fd())) && !cmd.Flags().Changed("display-name") && !cmd.Flags().Changed("description") && !cmd.Flags().Changed("confirm") && !cmd.Flags().Changed("no-confirm") && !cmd.Flags().Changed("tags") {
		displayName := current.DisplayName
		description := current.Description
		confirm := current.Confirm
		var newValue string

		form := huh.NewForm(
			huh.NewGroup(
				huh.NewInput().
					Title("Display name").
					Description("Shown in 'tsm list'. Leave as-is to keep, blank to clear.").
					Value(&displayName),
				huh.NewText().
					Title("Description").
					Description(fmt.Sprintf("Current: %s", current.Description)).
					Value(&description),
				huh.NewInput().
					Title("New value (leave empty to keep current)").
					EchoMode(huh.EchoModePassword).
					Value(&newValue),
				huh.NewConfirm().
					Title("Require confirmation on every access?").
					Value(&confirm),
			),
		)
		if err := form.Run(); err != nil {
			return err
		}

		if displayName != current.DisplayName {
			params["display_name"] = displayName
		}
		if description != current.Description {
			params["description"] = description
		}
		if newValue != "" {
			params["value"] = newValue
		}
		if confirm != current.Confirm {
			params["confirm"] = confirm
		}
	} else {
		if cmd.Flags().Changed("display-name") {
			v, _ := cmd.Flags().GetString("display-name")
			params["display_name"] = v
		}
		if cmd.Flags().Changed("description") {
			v, _ := cmd.Flags().GetString("description")
			params["description"] = v
		}
		if cmd.Flags().Changed("confirm") {
			params["confirm"] = true
		}
		if cmd.Flags().Changed("no-confirm") {
			params["confirm"] = false
		}
		if cmd.Flags().Changed("tags") {
			v, _ := cmd.Flags().GetStringSlice("tags")
			params["tags"] = v
		}
	}

	if len(params) == 2 {
		fmt.Println("No changes specified.")
		return nil
	}

	if err := c.Call("vault.edit", params, nil); err != nil {
		return handleError(err)
	}

	if jsonOutput() {
		return printJSON(map[string]bool{"ok": true})
	}
	fmt.Printf("Secret '%s' updated.\n", name)
	return nil
}
