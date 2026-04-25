package cmd

import (
	"bytes"
	"encoding/json"
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
