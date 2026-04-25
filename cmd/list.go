package cmd

import (
	"fmt"
	"strings"

	"tsm/internal/client"

	"github.com/spf13/cobra"
)

type secretMetadata struct {
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Confirm     bool     `json:"confirm"`
	Tags        []string `json:"tags"`
}

func newListCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List secrets (names and descriptions, never values)",
		RunE: func(cmd *cobra.Command, args []string) error {
			return withClient(func(c client.Caller) error {
				return runList(c)
			})
		},
	}
}

func runList(c client.Caller) error {
	var secrets []secretMetadata
	if err := c.Call("vault.list", nil, &secrets); err != nil {
		return handleError(err)
	}

	if jsonOutput() {
		return printJSON(secrets)
	}

	if len(secrets) == 0 {
		fmt.Println("No secrets stored. Run 'tsm add' to add one.")
		return nil
	}

	for _, s := range secrets {
		confirm := ""
		if s.Confirm {
			confirm = " [confirm]"
		}
		tags := ""
		if len(s.Tags) > 0 {
			tags = " (" + strings.Join(s.Tags, ", ") + ")"
		}
		fmt.Printf("  %s%s%s\n", s.Name, confirm, tags)
		if s.Description != "" {
			fmt.Printf("    %s\n", s.Description)
		}
	}
	return nil
}
