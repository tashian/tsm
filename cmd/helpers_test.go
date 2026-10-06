package cmd

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"tsm/internal/jsonrpc"
)

func TestFormatError_RPCError(t *testing.T) {
	err := &jsonrpc.RPCError{Code: -32001, Message: "Vault is locked"}
	msg := formatRPCError(err)
	if msg == "" {
		t.Fatal("expected non-empty message")
	}
}

func TestFormatError_VaultLocked_HasGuidance(t *testing.T) {
	err := &jsonrpc.RPCError{Code: jsonrpc.CodeVaultLocked, Message: "Vault is locked"}
	msg := formatRPCError(err)
	if msg == "" {
		t.Fatal("expected guidance message")
	}
}

func TestPrintJSON(t *testing.T) {
	var buf bytes.Buffer
	data := map[string]any{"name": "test", "value": 42}
	err := printJSONTo(&buf, data)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(buf.Bytes(), &decoded); err != nil {
		t.Fatalf("output is not valid JSON: %s", buf.String())
	}
}

func TestFormatError_AuthUnavailable_DoesNotAskForTouchID(t *testing.T) {
	err := &jsonrpc.RPCError{
		Code:    jsonrpc.CodeAuthUnavailable,
		Message: "No fingerprints are enrolled for Touch ID. Add one in System Settings > Touch ID & Password.",
	}
	msg := formatRPCError(err)
	if !strings.Contains(msg, "No fingerprints are enrolled") {
		t.Errorf("expected daemon's reason in message, got %q", msg)
	}
	if strings.Contains(msg, "Authenticate via Touch ID to proceed") {
		t.Errorf("no prompt was shown; message must not ask for Touch ID: %q", msg)
	}
	if !strings.Contains(msg, "No Touch ID prompt was shown") {
		t.Errorf("expected guidance that no prompt was shown, got %q", msg)
	}
	// The daemon's reason carries the fix; a fixed lid/keyboard hint would be
	// wrong for lockout or enrollment causes.
	if strings.Contains(msg, "lid") || strings.Contains(msg, "keyboard") {
		t.Errorf("CLI must not add a cause-specific hint: %q", msg)
	}
}

func TestPrintJSON_CompactObjectWhenNotTTY(t *testing.T) {
	var buf bytes.Buffer
	if err := printJSONTo(&buf, map[string]any{"locked": true, "version": "1.0"}); err != nil {
		t.Fatal(err)
	}
	want := `{"locked":true,"version":"1.0"}` + "\n"
	if buf.String() != want {
		t.Errorf("got %q, want %q", buf.String(), want)
	}
}

// An array prints one element per line, so `| head -N` shows N-2 whole
// entries and the output is still one valid JSON document.
func TestPrintJSON_ArrayOneElementPerLineWhenNotTTY(t *testing.T) {
	var buf bytes.Buffer
	in := []map[string]any{{"name": "a"}, {"name": "b"}}
	if err := printJSONTo(&buf, in); err != nil {
		t.Fatal(err)
	}
	want := "[\n" + `{"name":"a"},` + "\n" + `{"name":"b"}` + "\n]\n"
	if buf.String() != want {
		t.Errorf("got %q, want %q", buf.String(), want)
	}
	var decoded []map[string]any
	if err := json.Unmarshal(buf.Bytes(), &decoded); err != nil || len(decoded) != 2 {
		t.Fatalf("not a valid 2-element array: %v %s", err, buf.String())
	}
}

func TestPrintJSON_EmptyArray(t *testing.T) {
	var buf bytes.Buffer
	if err := printJSONTo(&buf, []string{}); err != nil {
		t.Fatal(err)
	}
	if buf.String() != "[]\n" {
		t.Errorf("got %q, want %q", buf.String(), "[]\n")
	}
}

func TestWriteError_JSON_RPCErrorHasCodeAndName(t *testing.T) {
	var buf bytes.Buffer
	writeError(&buf, &jsonrpc.RPCError{Code: jsonrpc.CodeAuthRequired, Message: "Authentication required"}, true)

	var got struct {
		Error struct {
			Code    int    `json:"code"`
			Name    string `json:"name"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(buf.Bytes(), &got); err != nil {
		t.Fatalf("invalid JSON: %s", buf.String())
	}
	if got.Error.Code != -32002 || got.Error.Name != "auth_required" || got.Error.Message != "Authentication required" {
		t.Errorf("unexpected error object: %+v", got.Error)
	}
}

func TestWriteError_JSON_PlainErrorHasMessageOnly(t *testing.T) {
	var buf bytes.Buffer
	writeError(&buf, errors.New("daemon did not start"), true)
	want := `{"error":{"message":"daemon did not start"}}` + "\n"
	if buf.String() != want {
		t.Errorf("got %q, want %q", buf.String(), want)
	}
}

func TestWriteError_Text(t *testing.T) {
	var buf bytes.Buffer
	writeError(&buf, errors.New("boom"), false)
	if buf.String() != "Error: boom\n" {
		t.Errorf("got %q", buf.String())
	}
}

func TestErrorName_KnownCodes(t *testing.T) {
	cases := map[int]string{
		jsonrpc.CodeVaultLocked:     "vault_locked",
		jsonrpc.CodeAuthRequired:    "auth_required",
		jsonrpc.CodeSecretNotFound:  "secret_not_found",
		jsonrpc.CodeAuthUnavailable: "auth_unavailable",
		-32601:                      "method_not_found",
		-1:                          "error",
	}
	for code, want := range cases {
		if got := errorName(code); got != want {
			t.Errorf("errorName(%d) = %q, want %q", code, got, want)
		}
	}
}

// In --json mode the RPC error must come back intact so Execute can write
// it to stderr as JSON; nothing may go to stdout, where data belongs.
func TestHandleError_JSONModeReturnsRPCError(t *testing.T) {
	prev := jsonFlag
	jsonFlag = true
	t.Cleanup(func() { jsonFlag = prev })

	in := &jsonrpc.RPCError{Code: jsonrpc.CodeAuthRequired, Message: "Authentication required"}
	var rpcErr *jsonrpc.RPCError
	if !errors.As(handleError(in), &rpcErr) || rpcErr.Code != jsonrpc.CodeAuthRequired {
		t.Fatalf("expected the RPC error back, got %v", handleError(in))
	}
}
