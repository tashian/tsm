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
}

func newListCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list [term...]",
		Short: "List secrets (names and descriptions, never values)",
		Long: `List secrets: names, display names, descriptions, tags, and the confirm
flag. Never values.

With terms, list only the secrets where any term appears in the name,
display name, description, or a tag. Matching ignores case.

Examples:
  tsm list
  tsm list anthropic
  tsm list aws amazon --json`,
		RunE: func(cmd *cobra.Command, args []string) error {
			return withUnlockedClient(func(c client.Caller) error {
				return runList(c, args, os.Stdout)
			})
		},
	}
}

func runList(c client.Caller, terms []string, stdout io.Writer) error {
	var secrets []secretMetadata
	if err := c.Call("vault.list", nil, &secrets); err != nil {
		return handleError(err)
	}
	secrets = filterSecrets(secrets, terms)

	if jsonOutput() {
		return printJSONTo(stdout, secrets)
	}

	if len(secrets) == 0 {
		if len(terms) > 0 {
			fmt.Fprintf(stdout, "No secrets match %q.\n", strings.Join(terms, " "))
		} else {
			fmt.Fprintln(stdout, "No secrets stored. Run 'tsm add' to add one.")
		}
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
	}
	return nil
}

// filterSecrets keeps the secrets where any term appears, ignoring case, in
// the name, display name, description, or a tag. No terms keeps them all.
// The result is never nil, so JSON output is [] rather than null.
func filterSecrets(secrets []secretMetadata, terms []string) []secretMetadata {
	out := []secretMetadata{}
	for _, s := range secrets {
		if len(terms) == 0 || matchesAny(s, terms) {
			out = append(out, s)
		}
	}
	return out
}

func matchesAny(s secretMetadata, terms []string) bool {
	fields := append([]string{s.Name, s.DisplayName, s.Description}, s.Tags...)
	for _, term := range terms {
		t := strings.ToLower(term)
		for _, f := range fields {
			if strings.Contains(strings.ToLower(f), t) {
				return true
			}
		}
	}
	return false
}
