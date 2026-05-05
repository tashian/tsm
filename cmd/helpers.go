package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"golang.org/x/term"

	"tsm/internal/client"
	"tsm/internal/daemon"
	"tsm/internal/jsonrpc"
)

// clientID returns an identifier for audit logging.
func clientID() string {
	return fmt.Sprintf("cli/pid:%d", os.Getpid())
}

// withClient ensures the daemon is running, dials it, runs fn, and closes.
func withClient(fn func(c client.Caller) error) error {
	sockPath, err := daemon.EnsureRunning()
	if err != nil {
		return err
	}
	c, err := client.Dial(sockPath)
	if err != nil {
		return err
	}
	defer c.Close()
	return fn(c)
}

// withUnlockedClient is like withClient but also unlocks the vault before
// running fn. Triggers Touch ID if the vault is locked; no-op if already
// unlocked. Use this for commands that mutate or read secret data so the
// auth prompt happens before any TUI form, not after.
func withUnlockedClient(fn func(c client.Caller) error) error {
	return withClient(func(c client.Caller) error {
		if err := c.Call("vault.unlock", nil, nil); err != nil {
			return handleError(err)
		}
		return fn(c)
	})
}

// isTTY returns true if the given file descriptor is a terminal.
func isTTY(fd int) bool {
	return term.IsTerminal(fd)
}

// jsonOutput returns true if --json was passed.
func jsonOutput() bool {
	return jsonFlag
}

// printJSON writes v as indented JSON to stdout.
func printJSON(v any) error {
	return printJSONTo(os.Stdout, v)
}

func printJSONTo(w io.Writer, v any) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

// formatRPCError returns a human-friendly error message with guidance.
func formatRPCError(err *jsonrpc.RPCError) string {
	switch err.Code {
	case jsonrpc.CodeVaultLocked:
		return fmt.Sprintf("%s\nRun 'tsm unlock' to unlock the vault.", err.Message)
	case jsonrpc.CodeAuthRequired:
		return fmt.Sprintf("%s\nAuthenticate via Touch ID to proceed.", err.Message)
	case jsonrpc.CodeSecretNotFound:
		return fmt.Sprintf("%s\nRun 'tsm list' to see available secrets.", err.Message)
	case jsonrpc.CodeSecretOutOfScope:
		// Daemon includes {name, roots} in data so we can render an
		// actionable hint: which secret, where it's bound, what to do.
		name, _ := err.Data["name"].(string)
		roots := stringSliceFromData(err.Data["roots"])
		rootsStr := ""
		if len(roots) > 0 {
			rootsStr = roots[0]
			if len(roots) > 1 {
				rootsStr += " (or one of: " + strings.Join(roots, ", ") + ")"
			}
		}
		return fmt.Sprintf(
			"Secret %q is project-scoped to %s. cd into that directory to access it. Use 'tsm list --all' to see all bindings.",
			name, rootsStr,
		)
	default:
		return err.Message
	}
}

// stringSliceFromData unpacks a JSON array of strings out of an RPC error's
// untyped `data` map. Tolerant of nil and unexpected shapes.
func stringSliceFromData(v any) []string {
	arr, ok := v.([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(arr))
	for _, item := range arr {
		if s, ok := item.(string); ok {
			out = append(out, s)
		}
	}
	return out
}


// handleError formats and prints an error, returning it for cobra.
func handleError(err error) error {
	if rpcErr, ok := err.(*jsonrpc.RPCError); ok {
		if jsonOutput() {
			printJSON(map[string]any{
				"error": map[string]any{
					"code":    rpcErr.Code,
					"message": rpcErr.Message,
				},
			})
			return errors.New("")
		}
		return errors.New(formatRPCError(rpcErr))
	}
	return err
}
