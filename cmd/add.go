package cmd

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"tsm/internal/client"
	"tsm/internal/normalize"

	"github.com/charmbracelet/huh"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

// addOptions captures the flag inputs for runAddWith. Extracted for tests:
// production wires these from cobra; tests inject directly so we can also
// stub out the cwd resolver.
type addOptions struct {
	Name        string
	DisplayName string
	Description string
	Confirm     bool
	Tags        []string
	FromFile    string
	NoInput     bool
	Here        bool
	Projects    []string
	// Getwd is the cwd resolver used by --here. In production this is
	// os.Getwd; tests inject a deterministic stub.
	Getwd func() (string, error)
	// EvalSymlinks is filepath.EvalSymlinks in production.
	EvalSymlinks func(string) (string, error)
	// Stdin is the reader used in --no-input / piped mode.
	Stdin    io.Reader
	StdinTTY bool
	// Stdout is where status output (e.g., "Secret 'x' added.") goes.
	Stdout io.Writer
}

func newAddCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "add",
		Short: "Add a secret to the vault",
		Long: `Add a secret interactively via TUI, or non-interactively via flags and stdin.

Interactive:  tsm add
Piped:        echo "secret_value" | tsm add --name foo --no-input
From file:    tsm add --name foo --from-file /path/to/key
Project:      tsm add --here --name foo --no-input
Project:      tsm add --project /abs/path --name foo --no-input`,
		RunE: func(cmd *cobra.Command, args []string) error {
			name, _ := cmd.Flags().GetString("name")
			displayName, _ := cmd.Flags().GetString("display-name")
			description, _ := cmd.Flags().GetString("description")
			confirm, _ := cmd.Flags().GetBool("confirm")
			tags, _ := cmd.Flags().GetStringSlice("tags")
			fromFile, _ := cmd.Flags().GetString("from-file")
			noInput, _ := cmd.Flags().GetBool("no-input")
			here, _ := cmd.Flags().GetBool("here")
			projects, _ := cmd.Flags().GetStringArray("project")

			opts := addOptions{
				Name:         name,
				DisplayName:  displayName,
				Description:  description,
				Confirm:      confirm,
				Tags:         tags,
				FromFile:     fromFile,
				NoInput:      noInput,
				Here:         here,
				Projects:     projects,
				Getwd:        os.Getwd,
				EvalSymlinks: filepath.EvalSymlinks,
				Stdin:        os.Stdin,
				StdinTTY:     term.IsTerminal(int(os.Stdin.Fd())),
				Stdout:       os.Stdout,
			}
			return withUnlockedClient(func(c client.Caller) error {
				return runAddWith(c, opts)
			})
		},
	}
	cmd.Flags().String("name", "", "secret id (kebab-case). If omitted in interactive mode, derived from display name.")
	cmd.Flags().String("display-name", "", "human-readable name shown in 'tsm list' (defaults to --name)")
	cmd.Flags().String("description", "", "secret description")
	cmd.Flags().Bool("confirm", false, "require authentication on every access")
	cmd.Flags().StringSlice("tags", nil, "tags (comma-separated)")
	cmd.Flags().String("from-file", "", "read secret value from file")
	cmd.Flags().Bool("no-input", false, "non-interactive mode (read value from stdin)")
	cmd.Flags().Bool("here", false, "bind the secret to the current directory (project scope)")
	cmd.Flags().StringArray("project", nil, "absolute path to bind the secret to (repeatable; project scope)")
	return cmd
}

func runAddWith(c client.Caller, opts addOptions) error {
	name := opts.Name
	displayName := opts.DisplayName
	description := opts.Description
	confirm := opts.Confirm
	tags := opts.Tags
	fromFile := opts.FromFile
	noInput := opts.NoInput

	// Resolve project roots from --here / --project flags. We do this before
	// any prompting so an invalid path fails fast (and doesn't waste a Touch
	// ID / huh form in the process).
	roots, err := resolveProjectRoots(opts)
	if err != nil {
		return err
	}
	scope := "global"
	if len(roots) > 0 {
		scope = "project"
	}

	var value string

	if fromFile != "" {
		data, err := os.ReadFile(fromFile)
		if err != nil {
			return fmt.Errorf("read file: %w", err)
		}
		value = strings.TrimRight(string(data), "\n")
	} else if noInput || !opts.StdinTTY {
		scanner := bufio.NewScanner(opts.Stdin)
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
					DescriptionFunc(func() string {
						if displayName == "" {
							return `e.g. "OpenAI API key"`
						}
						id, err := normalize.Kebab(displayName)
						if err != nil {
							return "stored as: (invalid)"
						}
						return "stored as: " + id
					}, &displayName).
					Validate(func(s string) error {
						_, err := normalize.Kebab(s)
						return err
					}).
					Value(&displayName),
				huh.NewText().
					Title("Description").
					Description("What is this secret for?").
					Value(&description),
				huh.NewInput().
					Title("Secret value").
					EchoMode(huh.EchoModePassword).
					Validate(func(s string) error {
						if s == "" {
							return fmt.Errorf("value cannot be empty")
						}
						return nil
					}).
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

		id, err := normalize.Kebab(displayName)
		if err != nil {
			return err
		}
		name = id
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
	if displayName != "" {
		params["display_name"] = displayName
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
	if scope == "project" {
		params["scope"] = "project"
		params["roots"] = roots
	}

	if err := c.Call("vault.add", params, nil); err != nil {
		return handleError(err)
	}

	stdout := opts.Stdout
	if stdout == nil {
		stdout = os.Stdout
	}
	if jsonOutput() {
		return printJSONTo(stdout, map[string]bool{"ok": true})
	}
	if displayName != "" && displayName != name {
		fmt.Fprintf(stdout, "Secret '%s' added (id: %s).\n", displayName, name)
	} else {
		fmt.Fprintf(stdout, "Secret '%s' added.\n", name)
	}
	if scope == "project" {
		fmt.Fprintf(stdout, "  scope: project (%s)\n", strings.Join(roots, ", "))
	}
	return nil
}

// resolveProjectRoots returns normalized absolute roots from --here and
// --project flags, or nil for global scope. Symlinks are resolved at
// add-time only — the daemon does not re-resolve.
func resolveProjectRoots(opts addOptions) ([]string, error) {
	var roots []string
	seen := map[string]bool{}

	add := func(p string) error {
		if !filepath.IsAbs(p) {
			return fmt.Errorf("--project path must be absolute: %q", p)
		}
		// Resolve symlinks so the stored root matches what the daemon will
		// see via proc_pidinfo (which returns realpaths). If the path doesn't
		// exist we warn-only — a project root might be on an unmounted volume.
		resolved := filepath.Clean(p)
		if opts.EvalSymlinks != nil {
			if r, err := opts.EvalSymlinks(p); err == nil {
				resolved = r
			} else {
				fmt.Fprintf(os.Stderr, "warning: could not resolve %q (%v); storing as-is\n", p, err)
			}
		}
		if seen[resolved] {
			return nil
		}
		seen[resolved] = true
		roots = append(roots, resolved)
		return nil
	}

	if opts.Here {
		if opts.Getwd == nil {
			return nil, fmt.Errorf("--here requires a getwd resolver (internal error)")
		}
		cwd, err := opts.Getwd()
		if err != nil {
			return nil, fmt.Errorf("--here: %w", err)
		}
		if err := add(cwd); err != nil {
			return nil, err
		}
	}
	for _, p := range opts.Projects {
		if err := add(p); err != nil {
			return nil, err
		}
	}
	return roots, nil
}
