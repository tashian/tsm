package cmd

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"

	"golang.org/x/term"

	"tsm/internal/client"
	"tsm/internal/daemon"
	"tsm/internal/jsonrpc"
)

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

// printJSON writes v as JSON to stdout.
func printJSON(v any) error {
	return printJSONTo(os.Stdout, v)
}

// printJSONTo writes v as JSON to w: indented for a terminal, compact
// otherwise. A compact array puts one element per line, so the output stays
// one JSON document and `| head -N` still shows whole entries.
func printJSONTo(w io.Writer, v any) error {
	if f, ok := w.(*os.File); ok && isTTY(int(f.Fd())) {
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		return enc.Encode(v)
	}

	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	var items []json.RawMessage
	if len(b) > 0 && b[0] == '[' && json.Unmarshal(b, &items) == nil && len(items) > 0 {
		var buf bytes.Buffer
		buf.WriteString("[\n")
		for i, item := range items {
			if i > 0 {
				buf.WriteString(",\n")
			}
			buf.Write(item)
		}
		buf.WriteString("\n]\n")
		_, err = w.Write(buf.Bytes())
		return err
	}
	_, err = w.Write(append(b, '\n'))
	return err
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
	case jsonrpc.CodeAuthUnavailable:
		return fmt.Sprintf("%s\nNo Touch ID prompt was shown. Fix the cause above, then try again.", err.Message)
	default:
		return err.Message
	}
}

// errorName returns a stable snake_case name for a JSON-RPC error code, so
// scripts can match on a word instead of a number.
func errorName(code int) string {
	switch code {
	case jsonrpc.CodeVaultLocked:
		return "vault_locked"
	case jsonrpc.CodeAuthRequired:
		return "auth_required"
	case jsonrpc.CodeSecretNotFound:
		return "secret_not_found"
	case jsonrpc.CodeAuthUnavailable:
		return "auth_unavailable"
	case -32700:
		return "parse_error"
	case -32600:
		return "invalid_request"
	case -32601:
		return "method_not_found"
	case -32602:
		return "invalid_params"
	case -32603:
		return "internal_error"
	default:
		return "error"
	}
}

// handleError adds guidance to an RPC error for the text output. In --json
// mode it returns the RPC error unchanged, and Execute writes it to stderr.
func handleError(err error) error {
	if rpcErr, ok := err.(*jsonrpc.RPCError); ok {
		if jsonOutput() {
			return rpcErr
		}
		return errors.New(formatRPCError(rpcErr))
	}
	return err
}

// writeError writes a command's final error to w (stderr in production). In
// --json mode it is {"error":{...}}, with code and name for RPC errors.
// Errors never go to stdout, so stdout holds data or nothing.
func writeError(w io.Writer, err error, asJSON bool) {
	if !asJSON {
		if err.Error() != "" {
			fmt.Fprintln(w, "Error:", err)
		}
		return
	}
	var obj any = map[string]any{"message": err.Error()}
	var rpcErr *jsonrpc.RPCError
	if errors.As(err, &rpcErr) {
		obj = map[string]any{
			"code":    rpcErr.Code,
			"name":    errorName(rpcErr.Code),
			"message": rpcErr.Message,
		}
	}
	printJSONTo(w, map[string]any{"error": obj})
}
