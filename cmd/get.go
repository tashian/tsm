package cmd

import (
	"fmt"
	"io"
	"os"
	"strings"

	"tsm/internal/client"
	"tsm/internal/format"

	"github.com/spf13/cobra"
	"golang.org/x/term"
)

// getOptions captures the inputs for runGetWith. Extracted for testability:
// production wires these from cobra flags + os.Stdout; tests inject directly.
type getOptions struct {
	Raw       bool
	ToFile    string
	Format    string // formatter name + optional inline args, space-separated
	Stdout    io.Writer
	StdoutTTY bool
}

func newGetCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "get <name>",
		Short: "Retrieve a secret value",
		Long: `Retrieve a secret by name.

Default:    JSON to stdout    {"name": "...", "value": "..."}
--raw:      Raw value only    (refuses if stdout is a TTY)
--to-file:  Write to file     (mode 0600, raw value, no newline)
--format F: Run value through formatter F (refuses if stdout is a TTY)
            Built-ins: env VAR, aws-credential-process, pgpass`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			raw, _ := cmd.Flags().GetBool("raw")
			toFile, _ := cmd.Flags().GetString("to-file")
			fmtSpec, _ := cmd.Flags().GetString("format")
			return withUnlockedClient(func(c client.Caller) error {
				return runGetWith(c, args[0], getOptions{
					Raw:       raw,
					ToFile:    toFile,
					Format:    fmtSpec,
					Stdout:    os.Stdout,
					StdoutTTY: term.IsTerminal(int(os.Stdout.Fd())),
				})
			})
		},
	}
	cmd.Flags().Bool("raw", false, "output raw secret value (no JSON, no newline)")
	cmd.Flags().String("to-file", "", "write secret value to file (mode 0600)")
	cmd.Flags().String("format", "", "run value through a formatter (e.g., 'env GITHUB_TOKEN', 'aws-credential-process', 'pgpass')")
	return cmd
}

func runGetWith(c client.Caller, name string, opts getOptions) error {
	// Mutex check: --format is exclusive with --raw, --to-file, and --json.
	if opts.Format != "" {
		if opts.Raw {
			return fmt.Errorf("--format cannot be combined with --raw")
		}
		if opts.ToFile != "" {
			return fmt.Errorf("--format cannot be combined with --to-file")
		}
		if jsonOutput() {
			return fmt.Errorf("--format cannot be combined with --json")
		}
	}

	var secret struct {
		Name  string `json:"name"`
		Value string `json:"value"`
	}
	if err := c.Call("vault.get", map[string]any{"name": name, "client_id": clientID()}, &secret); err != nil {
		return handleError(err)
	}

	if opts.ToFile != "" {
		if err := os.WriteFile(opts.ToFile, []byte(secret.Value), 0o600); err != nil {
			return fmt.Errorf("write to file: %w", err)
		}
		if !jsonOutput() {
			fmt.Printf("Secret written to %s\n", opts.ToFile)
		}
		return nil
	}

	if opts.Format != "" {
		if opts.StdoutTTY {
			return fmt.Errorf("refusing to write secret to terminal in --format mode\nPipe to a file or redirect: tsm get %s --format %q > out", name, opts.Format)
		}
		fmtName, args := splitFormatSpec(opts.Format)
		f, ok := format.Get(fmtName)
		if !ok {
			return fmt.Errorf("unknown formatter %q (built-ins: env, aws-credential-process, pgpass)", fmtName)
		}
		out, err := f.Format(secret.Value, args)
		if err != nil {
			return err
		}
		_, err = opts.Stdout.Write(out)
		return err
	}

	if opts.Raw {
		if opts.StdoutTTY {
			return fmt.Errorf("refusing to write secret to terminal in --raw mode\nPipe to a command or redirect: tsm get %s --raw | some-tool", name)
		}
		fmt.Fprint(opts.Stdout, secret.Value)
		return nil
	}

	return printJSON(secret)
}

// splitFormatSpec splits "env GITHUB_TOKEN" into ("env", ["GITHUB_TOKEN"]).
// A spec with no whitespace returns (name, nil).
func splitFormatSpec(spec string) (string, []string) {
	parts := strings.Fields(spec)
	if len(parts) == 0 {
		return "", nil
	}
	return parts[0], parts[1:]
}
