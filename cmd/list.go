package cmd

import (
	"fmt"
	"io"
	"os"
	"strings"

	"tsm/internal/client"

	"github.com/spf13/cobra"
)

type secretMetadata struct {
	Name        string   `json:"name"`
	DisplayName string   `json:"display_name"`
	Description string   `json:"description"`
	Confirm     bool     `json:"confirm"`
	Tags        []string `json:"tags"`
	Scope       string   `json:"scope"`
	Roots       []string `json:"roots"`
}

// listOptions captures inputs for runListWith. Extracted for testability.
type listOptions struct {
	All    bool
	Stdout io.Writer
}

func newListCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "list",
		Short: "List secrets (names and descriptions, never values)",
		Long: `List secrets visible to the current directory.

By default, project-scoped secrets bound to other directories are hidden —
this prevents an agent from seeing secret names it has no business with.
Pass --all to enumerate every secret regardless of project binding.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			all, _ := cmd.Flags().GetBool("all")
			return withUnlockedClient(func(c client.Caller) error {
				return runListWith(c, listOptions{All: all, Stdout: os.Stdout})
			})
		},
	}
	cmd.Flags().Bool("all", false, "include project-scoped secrets bound to other directories")
	return cmd
}

func runListWith(c client.Caller, opts listOptions) error {
	stdout := opts.Stdout
	if stdout == nil {
		stdout = os.Stdout
	}

	params := map[string]any{}
	if opts.All {
		params["include_all"] = true
	}

	var secrets []secretMetadata
	if err := c.Call("vault.list", params, &secrets); err != nil {
		return handleError(err)
	}

	if jsonOutput() {
		return printJSONTo(stdout, secrets)
	}

	if len(secrets) == 0 {
		fmt.Fprintln(stdout, "No secrets stored. Run 'tsm add' to add one.")
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
		label := s.Name
		if s.DisplayName != "" && s.DisplayName != s.Name {
			label = s.DisplayName
		}
		fmt.Fprintf(stdout, "  %s%s%s\n", label, confirm, tags)
		if s.DisplayName != "" && s.DisplayName != s.Name {
			fmt.Fprintf(stdout, "    id: %s\n", s.Name)
		}
		if s.Description != "" {
			fmt.Fprintf(stdout, "    %s\n", s.Description)
		}
		if s.Scope == "project" && len(s.Roots) > 0 {
			fmt.Fprintf(stdout, "    scope: project (%s)\n", strings.Join(s.Roots, ", "))
		}
	}
	return nil
}
