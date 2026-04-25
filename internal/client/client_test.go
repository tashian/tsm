package client

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"

	"tsm/internal/jsonrpc"
)

// fakeServer creates a Unix socket that accepts one connection,
// reads a JSON-RPC request, and writes a canned response.
func fakeServer(t *testing.T, response jsonrpc.Response) string {
	t.Helper()
	dir := t.TempDir()
	sock := filepath.Join(dir, "test.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })

	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()

		dec := json.NewDecoder(conn)
		var req jsonrpc.Request
		if err := dec.Decode(&req); err != nil {
			return
		}

		data, _ := json.Marshal(response)
		data = append(data, '\n')
		conn.Write(data)
	}()

	return sock
}

func TestDial_Success(t *testing.T) {
	sock := fakeServer(t, jsonrpc.Response{
		JSONRPC: "2.0",
		Result:  json.RawMessage(`{"ok":true}`),
		ID:      1,
	})

	c, err := Dial(sock)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
}

func TestDial_NoSocket(t *testing.T) {
	_, err := Dial("/tmp/nonexistent-tsm-test.sock")
	if err == nil {
		t.Fatal("expected error dialing nonexistent socket")
	}
}

func TestCall_Success(t *testing.T) {
	sock := fakeServer(t, jsonrpc.Response{
		JSONRPC: "2.0",
		Result:  json.RawMessage(`{"locked":false,"ttl_remaining_seconds":3600,"secret_count":2}`),
		ID:      1,
	})

	c, err := Dial(sock)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	var status struct {
		Locked              bool `json:"locked"`
		TTLRemainingSeconds int  `json:"ttl_remaining_seconds"`
		SecretCount         int  `json:"secret_count"`
	}
	err = c.Call("vault.status", nil, &status)
	if err != nil {
		t.Fatal(err)
	}
	if status.Locked {
		t.Fatal("expected unlocked")
	}
	if status.SecretCount != 2 {
		t.Fatalf("expected 2 secrets, got %d", status.SecretCount)
	}
}

func TestCall_RPCError(t *testing.T) {
	errResp := jsonrpc.Response{
		JSONRPC: "2.0",
		Error: &jsonrpc.RPCError{
			Code:    -32001,
			Message: "Vault is locked",
			Data:    map[string]any{"auth_method": "touchid"},
		},
		ID: 1,
	}
	sock := fakeServer(t, errResp)

	c, err := Dial(sock)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	var result struct{}
	err = c.Call("vault.status", nil, &result)
	if err == nil {
		t.Fatal("expected error")
	}
	rpcErr, ok := err.(*jsonrpc.RPCError)
	if !ok {
		t.Fatalf("expected *jsonrpc.RPCError, got %T", err)
	}
	if rpcErr.Code != -32001 {
		t.Fatalf("expected -32001, got %d", rpcErr.Code)
	}
}

func TestCall_WithParams(t *testing.T) {
	dir := t.TempDir()
	sock := filepath.Join(dir, "test.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })

	var receivedMethod string
	var receivedParams map[string]any
	done := make(chan struct{})

	go func() {
		defer close(done)
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()

		dec := json.NewDecoder(conn)
		var req jsonrpc.Request
		if err := dec.Decode(&req); err != nil {
			return
		}
		receivedMethod = req.Method
		receivedParams = req.Params

		resp := jsonrpc.Response{
			JSONRPC: "2.0",
			Result:  json.RawMessage(`{"name":"api_key","value":"secret123"}`),
			ID:      req.ID,
		}
		data, _ := json.Marshal(resp)
		data = append(data, '\n')
		conn.Write(data)
	}()

	c, err := Dial(sock)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	var secret struct {
		Name  string `json:"name"`
		Value string `json:"value"`
	}
	err = c.Call("vault.get", map[string]any{"name": "api_key"}, &secret)
	if err != nil {
		t.Fatal(err)
	}
	<-done
	if receivedMethod != "vault.get" {
		t.Fatalf("expected vault.get, got %s", receivedMethod)
	}
	if receivedParams["name"] != "api_key" {
		t.Fatalf("expected api_key param, got %v", receivedParams["name"])
	}
	if secret.Value != "secret123" {
		t.Fatalf("expected secret123, got %s", secret.Value)
	}
}

func TestIsSocketLive(t *testing.T) {
	dir := t.TempDir()
	sock := filepath.Join(dir, "live.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	if !IsSocketLive(sock) {
		t.Fatal("expected live socket to be detected")
	}

	stale := filepath.Join(dir, "stale.sock")
	os.WriteFile(stale, []byte{}, 0o600)
	if IsSocketLive(stale) {
		t.Fatal("expected stale socket to not be live")
	}

	if IsSocketLive(filepath.Join(dir, "nope.sock")) {
		t.Fatal("expected nonexistent socket to not be live")
	}
}
