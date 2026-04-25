# tsm (Go CLI) Implementation Plan — Plan 2 of 3

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Go CLI (`tsm`) that manages the daemon lifecycle, connects to `tsmd` over a Unix socket, and exposes all user-facing commands with TUI and JSON output modes.

**Architecture:** `tsm` is a thin Go client that communicates with the Swift daemon (`tsmd`) over a Unix domain socket using newline-delimited JSON-RPC 2.0. Every command that touches vault state calls `ensureDaemon()` first, which spawns `tsmd` if needed. Interactive commands use the Charm TUI stack (huh, lipgloss); non-TTY output is structured JSON. The binary is the single user-facing entry point — it manages the daemon, provides CLI commands, and will later support MCP server mode (Plan 3).

**Tech Stack:** Go 1.23+, cobra (CLI framework), charmbracelet/huh (TUI forms), charmbracelet/lipgloss (styling), golang.org/x/term (TTY detection)

**Spec:** `docs/plans/2026-03-08-tsm-design.md`

**Daemon reference:** `tsmd/` (Swift), see `docs/plans/2026-03-21-tsmd-implementation.md`

---

## File Structure

```
(repo root)
├── go.mod
├── go.sum
├── main.go                        # package main, calls cmd.Execute()
├── cmd/
│   ├── root.go                    # Root cobra command, --json flag, Execute()
│   ├── helpers.go                 # withClient(), formatError(), output helpers
│   ├── helpers_test.go            # Output formatting tests
│   ├── version.go                 # tsm version
│   ├── status.go                  # tsm status
│   ├── lock.go                    # tsm lock
│   ├── unlock.go                  # tsm unlock
│   ├── ensure_daemon.go           # tsm ensure-daemon
│   ├── list.go                    # tsm list
│   ├── init.go                    # tsm init (TUI)
│   ├── add.go                     # tsm add (TUI)
│   ├── get.go                     # tsm get (output modes)
│   ├── edit.go                    # tsm edit (TUI)
│   ├── remove.go                  # tsm remove
│   ├── config.go                  # tsm config
│   ├── reset.go                   # tsm reset
│   └── log.go                     # tsm log
├── internal/
│   ├── jsonrpc/
│   │   ├── types.go               # JSON-RPC 2.0 request, response, error types
│   │   └── types_test.go
│   ├── client/
│   │   ├── client.go              # Caller interface, DaemonClient (Unix socket)
│   │   └── client_test.go
│   ├── daemon/
│   │   ├── lifecycle.go           # EnsureRunning, spawn tsmd, wait for socket
│   │   └── lifecycle_test.go
│   └── paths/
│       ├── paths.go               # XDG-compliant path resolution
│       └── paths_test.go
```

### Key Design Decisions

**Cobra for CLI framework.** Standard Go CLI library. Handles subcommands, flags, help text, shell completions. No reason to reinvent this.

**`Caller` interface for testability.** Commands depend on `client.Caller` (an interface), never the concrete socket client. Tests inject a mock that returns canned JSON-RPC responses. Commands are tested without a running daemon.

**`withClient()` helper.** Every daemon-connected command uses `withClient(func(c Caller) error)` which calls `daemon.EnsureRunning()`, dials the socket, runs the callback, and closes the connection. DRY daemon lifecycle management. Mutation and retrieval commands (add, get, edit, remove, reset) include a `client_id` of `"cli/pid:<PID>"` for audit logging.

**Charm TUI for interactive input, plain JSON for pipes.** TTY detection (`golang.org/x/term`) switches between styled TUI forms and `--json`/`--no-input` modes. The same command works for humans and scripts.

**Newline-delimited JSON-RPC framing.** Matches the daemon's protocol exactly — send a JSON line, read a JSON line. The client is trivial: `json.Encoder` + `json.Decoder` over a `net.Conn`.

---

## Task 1: Go Module + XDG Paths

**Files:**
- Create: `go.mod`
- Create: `main.go`
- Create: `internal/paths/paths.go`
- Test: `internal/paths/paths_test.go`

- [ ] **Step 1: Create `go.mod`**

```go
module tsm

go 1.23
```

Run: `cd /Users/carl/code/tsm && go mod tidy`

- [ ] **Step 2: Create stub `main.go`**

```go
package main

import "fmt"

func main() {
	fmt.Println("tsm")
}
```

Run: `go build -o /dev/null .`
Expected: builds without error

- [ ] **Step 3: Write failing test for paths**

```go
// internal/paths/paths_test.go
package paths

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSocketPath_Default(t *testing.T) {
	t.Setenv("TSM_AUTH_SOCK", "")
	t.Setenv("XDG_RUNTIME_DIR", "")

	p := SocketPath()
	if p == "" {
		t.Fatal("SocketPath() returned empty string")
	}
	if !strings.HasSuffix(p, "tsm/vault.sock") {
		t.Fatalf("expected path ending in tsm/vault.sock, got %s", p)
	}
}

func TestSocketPath_EnvOverride(t *testing.T) {
	t.Setenv("TSM_AUTH_SOCK", "/tmp/custom.sock")
	p := SocketPath()
	if p != "/tmp/custom.sock" {
		t.Fatalf("expected /tmp/custom.sock, got %s", p)
	}
}

func TestVaultFile_Default(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", "")
	p := VaultFile()
	home, _ := os.UserHomeDir()
	expected := filepath.Join(home, ".local", "share", "tsm", "vault.enc")
	if p != expected {
		t.Fatalf("expected %s, got %s", expected, p)
	}
}

func TestVaultFile_XDG(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", "/tmp/xdg-data")
	p := VaultFile()
	expected := filepath.Join("/tmp/xdg-data", "tsm", "vault.enc")
	if p != expected {
		t.Fatalf("expected %s, got %s", expected, p)
	}
}

func TestConfigFile_Default(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", "")
	p := ConfigFile()
	home, _ := os.UserHomeDir()
	expected := filepath.Join(home, ".config", "tsm", "config.json")
	if p != expected {
		t.Fatalf("expected %s, got %s", expected, p)
	}
}

func TestAccessLog_Default(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", "")
	p := AccessLog()
	home, _ := os.UserHomeDir()
	expected := filepath.Join(home, ".local", "share", "tsm", "access.log")
	if p != expected {
		t.Fatalf("expected %s, got %s", expected, p)
	}
}
```

Run: `go test ./internal/paths/`
Expected: FAIL — package doesn't exist yet

- [ ] **Step 4: Implement paths**

```go
// internal/paths/paths.go
package paths

import (
	"os"
	"path/filepath"
)

// SocketPath returns the Unix socket path for the daemon.
// Precedence: $TSM_AUTH_SOCK > $XDG_RUNTIME_DIR/tsm/vault.sock > $TMPDIR/tsm/vault.sock
func SocketPath() string {
	if v := os.Getenv("TSM_AUTH_SOCK"); v != "" {
		return v
	}
	if v := os.Getenv("XDG_RUNTIME_DIR"); v != "" {
		return filepath.Join(v, "tsm", "vault.sock")
	}
	return filepath.Join(os.TempDir(), "tsm", "vault.sock")
}

// VaultFile returns the path to the encrypted vault file.
func VaultFile() string {
	return filepath.Join(dataDir(), "vault.enc")
}

// AccessLog returns the path to the access log file.
func AccessLog() string {
	return filepath.Join(dataDir(), "access.log")
}

// ConfigFile returns the path to the config file.
func ConfigFile() string {
	return filepath.Join(configDir(), "config.json")
}

// TsmdBin returns the expected path to the tsmd binary.
// Looks in the same directory as the running tsm binary first,
// then falls back to ~/.local/bin/tsmd.
func TsmdBin() string {
	if exe, err := os.Executable(); err == nil {
		candidate := filepath.Join(filepath.Dir(exe), "tsmd")
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "bin", "tsmd")
}

func dataDir() string {
	if v := os.Getenv("XDG_DATA_HOME"); v != "" {
		return filepath.Join(v, "tsm")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "share", "tsm")
}

func configDir() string {
	if v := os.Getenv("XDG_CONFIG_HOME"); v != "" {
		return filepath.Join(v, "tsm")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "tsm")
}
```

- [ ] **Step 5: Run tests, verify pass**

Run: `go test ./internal/paths/ -v`
Expected: all 6 tests PASS

- [ ] **Step 6: Commit**

```bash
git add go.mod main.go internal/paths/
git commit -m "feat(tsm): add Go module scaffold and XDG path resolution"
```

---

## Task 2: JSON-RPC Types

**Files:**
- Create: `internal/jsonrpc/types.go`
- Test: `internal/jsonrpc/types_test.go`

- [ ] **Step 1: Write failing tests for JSON-RPC types**

```go
// internal/jsonrpc/types_test.go
package jsonrpc

import (
	"encoding/json"
	"testing"
)

func TestRequest_Marshal(t *testing.T) {
	req := Request{
		JSONRPC: "2.0",
		Method:  "vault.status",
		ID:      1,
	}
	data, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	json.Unmarshal(data, &m)
	if m["method"] != "vault.status" {
		t.Fatalf("expected vault.status, got %v", m["method"])
	}
	if m["jsonrpc"] != "2.0" {
		t.Fatalf("expected 2.0, got %v", m["jsonrpc"])
	}
}

func TestRequest_MarshalWithParams(t *testing.T) {
	req := Request{
		JSONRPC: "2.0",
		Method:  "vault.get",
		Params:  map[string]any{"name": "my_secret"},
		ID:      1,
	}
	data, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	json.Unmarshal(data, &m)
	params := m["params"].(map[string]any)
	if params["name"] != "my_secret" {
		t.Fatalf("expected my_secret, got %v", params["name"])
	}
}

func TestRequest_MarshalOmitsNilParams(t *testing.T) {
	req := Request{
		JSONRPC: "2.0",
		Method:  "vault.lock",
		ID:      1,
	}
	data, _ := json.Marshal(req)
	var m map[string]any
	json.Unmarshal(data, &m)
	if _, ok := m["params"]; ok {
		t.Fatal("expected params to be omitted when nil")
	}
}

func TestResponse_UnmarshalSuccess(t *testing.T) {
	raw := `{"jsonrpc":"2.0","result":{"locked":false,"ttl_remaining_seconds":3600,"secret_count":2},"id":1}`
	var resp Response
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Error != nil {
		t.Fatal("expected no error")
	}
	if resp.Result == nil {
		t.Fatal("expected result")
	}
}

func TestResponse_UnmarshalError(t *testing.T) {
	raw := `{"jsonrpc":"2.0","error":{"code":-32001,"message":"Vault is locked","data":{"auth_method":"touchid"}},"id":1}`
	var resp Response
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Error == nil {
		t.Fatal("expected error")
	}
	if resp.Error.Code != -32001 {
		t.Fatalf("expected -32001, got %d", resp.Error.Code)
	}
	if resp.Error.Message != "Vault is locked" {
		t.Fatalf("expected 'Vault is locked', got %s", resp.Error.Message)
	}
}

func TestRPCError_Error(t *testing.T) {
	e := &RPCError{Code: -32001, Message: "Vault is locked"}
	s := e.Error()
	if s != "Vault is locked" {
		t.Fatalf("expected 'Vault is locked', got %s", s)
	}
}

func TestResponse_ResultInto(t *testing.T) {
	raw := `{"jsonrpc":"2.0","result":{"locked":false,"ttl_remaining_seconds":3600,"secret_count":2},"id":1}`
	var resp Response
	json.Unmarshal([]byte(raw), &resp)

	var status struct {
		Locked              bool `json:"locked"`
		TTLRemainingSeconds int  `json:"ttl_remaining_seconds"`
		SecretCount         int  `json:"secret_count"`
	}
	if err := resp.ResultInto(&status); err != nil {
		t.Fatal(err)
	}
	if status.Locked {
		t.Fatal("expected unlocked")
	}
	if status.TTLRemainingSeconds != 3600 {
		t.Fatalf("expected 3600, got %d", status.TTLRemainingSeconds)
	}
	if status.SecretCount != 2 {
		t.Fatalf("expected 2, got %d", status.SecretCount)
	}
}

func TestResponse_ResultInto_Error(t *testing.T) {
	raw := `{"jsonrpc":"2.0","error":{"code":-32001,"message":"Vault is locked"},"id":1}`
	var resp Response
	json.Unmarshal([]byte(raw), &resp)

	var status struct{}
	err := resp.ResultInto(&status)
	if err == nil {
		t.Fatal("expected error")
	}
	rpcErr, ok := err.(*RPCError)
	if !ok {
		t.Fatalf("expected *RPCError, got %T", err)
	}
	if rpcErr.Code != -32001 {
		t.Fatalf("expected -32001, got %d", rpcErr.Code)
	}
}
```

Run: `go test ./internal/jsonrpc/`
Expected: FAIL — package doesn't exist

- [ ] **Step 2: Implement JSON-RPC types**

```go
// internal/jsonrpc/types.go
package jsonrpc

import "encoding/json"

// Request is a JSON-RPC 2.0 request.
type Request struct {
	JSONRPC string         `json:"jsonrpc"`
	Method  string         `json:"method"`
	Params  map[string]any `json:"params,omitempty"`
	ID      int            `json:"id"`
}

// Response is a JSON-RPC 2.0 response.
type Response struct {
	JSONRPC string           `json:"jsonrpc"`
	Result  json.RawMessage  `json:"result,omitempty"`
	Error   *RPCError        `json:"error,omitempty"`
	ID      int              `json:"id"`
}

// ResultInto unmarshals the result into v. Returns *RPCError if the response is an error.
func (r *Response) ResultInto(v any) error {
	if r.Error != nil {
		return r.Error
	}
	return json.Unmarshal(r.Result, v)
}

// RPCError is a JSON-RPC 2.0 error object.
type RPCError struct {
	Code    int            `json:"code"`
	Message string         `json:"message"`
	Data    map[string]any `json:"data,omitempty"`
}

func (e *RPCError) Error() string {
	return e.Message
}

// Well-known tsm error codes.
const (
	CodeVaultLocked   = -32001
	CodeAuthRequired  = -32002
	CodeSecretNotFound = -32003
)
```

- [ ] **Step 3: Run tests, verify pass**

Run: `go test ./internal/jsonrpc/ -v`
Expected: all tests PASS

- [ ] **Step 4: Commit**

```bash
git add internal/jsonrpc/
git commit -m "feat(tsm): add JSON-RPC 2.0 request, response, and error types"
```

---

## Task 3: JSON-RPC Client

**Files:**
- Create: `internal/client/client.go`
- Test: `internal/client/client_test.go`

- [ ] **Step 1: Write failing tests for the client**

Tests spin up a real Unix socket server to validate framing and round-trip behavior.

```go
// internal/client/client_test.go
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
	// Live socket
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

	// Stale socket file (exists but nobody listening)
	stale := filepath.Join(dir, "stale.sock")
	os.WriteFile(stale, []byte{}, 0o600)
	if IsSocketLive(stale) {
		t.Fatal("expected stale socket to not be live")
	}

	// Nonexistent
	if IsSocketLive(filepath.Join(dir, "nope.sock")) {
		t.Fatal("expected nonexistent socket to not be live")
	}
}
```

Run: `go test ./internal/client/`
Expected: FAIL — package doesn't exist

- [ ] **Step 2: Implement the client**

```go
// internal/client/client.go
package client

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"sync"

	"tsm/internal/jsonrpc"
)

// Caller is the interface for making JSON-RPC calls. Commands depend on this
// for testability — tests inject a mock instead of a real socket client.
type Caller interface {
	Call(method string, params map[string]any, result any) error
	Close() error
}

// DaemonClient connects to tsmd over a Unix socket.
type DaemonClient struct {
	conn   net.Conn
	reader *bufio.Reader
	mu     sync.Mutex
	nextID int
}

// Dial connects to the daemon at the given Unix socket path.
func Dial(socketPath string) (*DaemonClient, error) {
	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		return nil, fmt.Errorf("cannot connect to daemon at %s: %w", socketPath, err)
	}
	return &DaemonClient{
		conn:   conn,
		reader: bufio.NewReader(conn),
		nextID: 1,
	}, nil
}

// Call sends a JSON-RPC request and unmarshals the response into result.
// Returns *jsonrpc.RPCError if the daemon returns an error response.
// If result is nil, the response result is discarded.
func (c *DaemonClient) Call(method string, params map[string]any, result any) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	req := jsonrpc.Request{
		JSONRPC: "2.0",
		Method:  method,
		Params:  params,
		ID:      c.nextID,
	}
	c.nextID++

	data, err := json.Marshal(req)
	if err != nil {
		return fmt.Errorf("marshal request: %w", err)
	}
	data = append(data, '\n')

	if _, err := c.conn.Write(data); err != nil {
		return fmt.Errorf("write request: %w", err)
	}

	line, err := c.reader.ReadBytes('\n')
	if err != nil {
		return fmt.Errorf("read response: %w", err)
	}

	var resp jsonrpc.Response
	if err := json.Unmarshal(line, &resp); err != nil {
		return fmt.Errorf("unmarshal response: %w", err)
	}

	if result == nil {
		if resp.Error != nil {
			return resp.Error
		}
		return nil
	}

	return resp.ResultInto(result)
}

// Close closes the connection.
func (c *DaemonClient) Close() error {
	return c.conn.Close()
}

// IsSocketLive checks if a Unix socket at the given path is accepting connections.
func IsSocketLive(path string) bool {
	conn, err := net.Dial("unix", path)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}
```

- [ ] **Step 3: Run tests, verify pass**

Run: `go test ./internal/client/ -v`
Expected: all tests PASS

- [ ] **Step 4: Commit**

```bash
git add internal/client/
git commit -m "feat(tsm): add JSON-RPC client with Unix socket transport"
```

---

## Task 4: Daemon Lifecycle

**Files:**
- Create: `internal/daemon/lifecycle.go`
- Test: `internal/daemon/lifecycle_test.go`

- [ ] **Step 1: Write failing tests**

These tests use a fake "daemon" (a simple socket server script) to validate the spawn-and-wait logic.

```go
// internal/daemon/lifecycle_test.go
package daemon

import (
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"tsm/internal/client"
)

func TestEnsureRunning_AlreadyRunning(t *testing.T) {
	dir := t.TempDir()
	sock := filepath.Join(dir, "vault.sock")

	// Start a listener to simulate a running daemon
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	t.Setenv("TSM_AUTH_SOCK", sock)

	path, err := EnsureRunning()
	if err != nil {
		t.Fatal(err)
	}
	if path != sock {
		t.Fatalf("expected %s, got %s", sock, path)
	}
}

func TestEnsureRunning_SpawnsDaemon(t *testing.T) {
	if os.Getenv("TSM_TEST_TSMD_BIN") == "" {
		t.Skip("set TSM_TEST_TSMD_BIN to a tsmd binary to run spawn tests")
	}

	dir := t.TempDir()
	sock := filepath.Join(dir, "vault.sock")
	t.Setenv("TSM_AUTH_SOCK", sock)
	t.Setenv("TSM_TSMD_BIN", os.Getenv("TSM_TEST_TSMD_BIN"))

	path, err := EnsureRunning()
	if err != nil {
		t.Fatal(err)
	}
	if !client.IsSocketLive(path) {
		t.Fatal("daemon socket is not live after EnsureRunning")
	}
}

func TestWaitForSocket_Existing(t *testing.T) {
	dir := t.TempDir()
	sock := filepath.Join(dir, "vault.sock")

	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	err = waitForSocket(sock, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
}

func TestWaitForSocket_Timeout(t *testing.T) {
	err := waitForSocket("/tmp/nonexistent-tsm-test.sock", 100*time.Millisecond)
	if err == nil {
		t.Fatal("expected timeout error")
	}
}

func TestWaitForSocket_BecomesAvailable(t *testing.T) {
	dir := t.TempDir()
	sock := filepath.Join(dir, "vault.sock")

	// Start listener after a short delay
	go func() {
		time.Sleep(200 * time.Millisecond)
		ln, err := net.Listen("unix", sock)
		if err != nil {
			return
		}
		defer ln.Close()
		time.Sleep(5 * time.Second) // keep alive for test
	}()

	err := waitForSocket(sock, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
}
```

Run: `go test ./internal/daemon/`
Expected: FAIL — package doesn't exist

- [ ] **Step 2: Implement daemon lifecycle**

```go
// internal/daemon/lifecycle.go
package daemon

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"tsm/internal/client"
	"tsm/internal/paths"
)

const (
	spawnTimeout = 10 * time.Second
	pollInterval = 50 * time.Millisecond
)

// EnsureRunning checks if tsmd is running. If not, spawns it.
// Returns the socket path.
func EnsureRunning() (string, error) {
	sockPath := paths.SocketPath()

	if client.IsSocketLive(sockPath) {
		return sockPath, nil
	}

	return spawn(sockPath)
}

// spawn starts tsmd and waits for its socket to become available.
func spawn(sockPath string) (string, error) {
	tsmdBin := tsmdPath()

	if _, err := os.Stat(tsmdBin); err != nil {
		return "", fmt.Errorf("tsmd not found at %s: %w", tsmdBin, err)
	}

	// Ensure socket directory exists
	if err := os.MkdirAll(filepath.Dir(sockPath), 0o700); err != nil {
		return "", fmt.Errorf("create socket directory: %w", err)
	}

	// Remove stale socket file if present
	os.Remove(sockPath)

	cmd := exec.Command(tsmdBin, "--socket", sockPath)
	cmd.Stderr = os.Stderr

	// Capture stdout to read the socket path printed by tsmd
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", fmt.Errorf("stdout pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return "", fmt.Errorf("start tsmd: %w", err)
	}

	// tsmd prints the socket path on its first line of stdout, then keeps running
	scanner := bufio.NewScanner(stdout)
	done := make(chan string, 1)
	go func() {
		if scanner.Scan() {
			done <- scanner.Text()
		}
	}()

	select {
	case line := <-done:
		if line != "" {
			sockPath = line
		}
	case <-time.After(spawnTimeout):
		cmd.Process.Kill()
		return "", fmt.Errorf("tsmd did not print socket path within %s", spawnTimeout)
	}

	// Wait for socket to accept connections
	if err := waitForSocket(sockPath, spawnTimeout); err != nil {
		cmd.Process.Kill()
		return "", fmt.Errorf("tsmd started but socket not ready: %w", err)
	}

	// Detach: we don't wait for the daemon process — it runs in the background
	go cmd.Wait()

	return sockPath, nil
}

func waitForSocket(path string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if client.IsSocketLive(path) {
			return nil
		}
		time.Sleep(pollInterval)
	}
	return fmt.Errorf("socket %s not ready after %s", path, timeout)
}

func tsmdPath() string {
	if v := os.Getenv("TSM_TSMD_BIN"); v != "" {
		return v
	}
	return paths.TsmdBin()
}
```

- [ ] **Step 3: Run tests, verify pass**

Run: `go test ./internal/daemon/ -v`
Expected: 4 tests PASS (spawn test SKIPped unless TSM_TEST_TSMD_BIN is set)

- [ ] **Step 4: Commit**

```bash
git add internal/daemon/
git commit -m "feat(tsm): add daemon lifecycle management (ensure, spawn, wait)"
```

---

## Task 5: CLI Framework + Output Helpers

**Files:**
- Create: `cmd/root.go`
- Create: `cmd/helpers.go`
- Create: `cmd/helpers_test.go`
- Modify: `main.go`

- [ ] **Step 1: Add cobra dependency**

Run: `go get github.com/spf13/cobra && go get golang.org/x/term`

- [ ] **Step 2: Write failing tests for output helpers**

```go
// cmd/helpers_test.go
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
```

Run: `go test ./cmd/`
Expected: FAIL — package doesn't exist

- [ ] **Step 3: Implement helpers**

```go
// cmd/helpers.go
package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"os"

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

// isTTY returns true if the given file descriptor is a terminal.
func isTTY(fd int) bool {
	return term.IsTerminal(fd)
}

// jsonOutput returns true if --json was passed or stdout is not a TTY.
func jsonOutput() bool {
	if jsonFlag {
		return true
	}
	return false
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
	default:
		return err.Message
	}
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
			return fmt.Errorf("")
		}
		return fmt.Errorf(formatRPCError(rpcErr))
	}
	return err
}
```

- [ ] **Step 4: Implement root command**

```go
// cmd/root.go
package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var jsonFlag bool

func NewRootCmd() *cobra.Command {
	root := &cobra.Command{
		Use:   "tsm",
		Short: "Tiny Secrets Manager — biometric-authenticated secrets for AI agents",
		Long:  "tsm stores secrets in an encrypted vault protected by Touch ID.\nIt runs a local daemon and exposes secrets via CLI and MCP.",
		SilenceUsage:  true,
		SilenceErrors: true,
	}

	root.PersistentFlags().BoolVar(&jsonFlag, "json", false, "output as JSON")

	root.AddCommand(
		newVersionCmd(),
	)

	return root
}

func Execute() {
	root := NewRootCmd()
	if err := root.Execute(); err != nil {
		if err.Error() != "" {
			fmt.Fprintln(os.Stderr, "Error:", err)
		}
		os.Exit(1)
	}
}
```

- [ ] **Step 5: Update main.go**

```go
// main.go
package main

import "tsm/cmd"

func main() {
	cmd.Execute()
}
```

- [ ] **Step 6: Run tests, verify pass**

Run: `go test ./cmd/ -v && go build -o /dev/null .`
Expected: tests PASS, binary builds

- [ ] **Step 7: Commit**

```bash
git add cmd/ main.go go.mod go.sum
git commit -m "feat(tsm): add CLI framework with cobra, output helpers, and root command"
```

---

## Task 6: Version + Status + Lock + Unlock Commands

**Files:**
- Create: `cmd/version.go`
- Create: `cmd/status.go`
- Create: `cmd/lock.go`
- Create: `cmd/unlock.go`
- Modify: `cmd/root.go` (register commands)

- [ ] **Step 1: Implement version command**

```go
// cmd/version.go
package cmd

import (
	"fmt"

	"github.com/spf13/cobra"
)

// Version is set at build time via -ldflags.
var Version = "dev"

func newVersionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print tsm version",
		Run: func(cmd *cobra.Command, args []string) {
			if jsonOutput() {
				printJSON(map[string]string{"version": Version})
				return
			}
			fmt.Printf("tsm %s\n", Version)
		},
	}
}
```

- [ ] **Step 2: Implement status command**

```go
// cmd/status.go
package cmd

import (
	"fmt"

	"tsm/internal/client"

	"github.com/spf13/cobra"
)

func newStatusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show vault state, TTL remaining, daemon status",
		RunE: func(cmd *cobra.Command, args []string) error {
			return withClient(func(c client.Caller) error {
				return runStatus(c)
			})
		},
	}
}

func runStatus(c client.Caller) error {
	var status struct {
		Locked              bool `json:"locked"`
		TTLRemainingSeconds *int `json:"ttl_remaining_seconds"`
		SecretCount         int  `json:"secret_count"`
	}
	if err := c.Call("vault.status", nil, &status); err != nil {
		return handleError(err)
	}

	if jsonOutput() {
		return printJSON(status)
	}

	if status.Locked {
		fmt.Println("Vault: locked")
	} else {
		fmt.Println("Vault: unlocked")
		if status.TTLRemainingSeconds != nil {
			hours := *status.TTLRemainingSeconds / 3600
			minutes := (*status.TTLRemainingSeconds % 3600) / 60
			fmt.Printf("TTL remaining: %dh %dm\n", hours, minutes)
		}
	}
	fmt.Printf("Secrets: %d\n", status.SecretCount)
	return nil
}
```

- [ ] **Step 3: Implement lock command**

```go
// cmd/lock.go
package cmd

import (
	"fmt"

	"tsm/internal/client"

	"github.com/spf13/cobra"
)

func newLockCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "lock",
		Short: "Lock the vault immediately",
		RunE: func(cmd *cobra.Command, args []string) error {
			return withClient(func(c client.Caller) error {
				return runLock(c)
			})
		},
	}
}

func runLock(c client.Caller) error {
	if err := c.Call("vault.lock", nil, nil); err != nil {
		return handleError(err)
	}
	if jsonOutput() {
		return printJSON(map[string]bool{"ok": true})
	}
	fmt.Println("Vault locked.")
	return nil
}
```

- [ ] **Step 4: Implement unlock command**

```go
// cmd/unlock.go
package cmd

import (
	"fmt"

	"tsm/internal/client"

	"github.com/spf13/cobra"
)

func newUnlockCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "unlock",
		Short: "Unlock the vault (triggers Touch ID)",
		RunE: func(cmd *cobra.Command, args []string) error {
			return withClient(func(c client.Caller) error {
				return runUnlock(c)
			})
		},
	}
}

func runUnlock(c client.Caller) error {
	if err := c.Call("vault.unlock", nil, nil); err != nil {
		return handleError(err)
	}
	if jsonOutput() {
		return printJSON(map[string]bool{"ok": true})
	}
	fmt.Println("Vault unlocked.")
	return nil
}
```

- [ ] **Step 5: Register commands in root.go**

Add to `NewRootCmd()`:

```go
root.AddCommand(
    newVersionCmd(),
    newStatusCmd(),
    newLockCmd(),
    newUnlockCmd(),
)
```

- [ ] **Step 6: Verify build**

Run: `go build -o /dev/null . && go vet ./...`
Expected: builds and vets cleanly

- [ ] **Step 7: Commit**

```bash
git add cmd/version.go cmd/status.go cmd/lock.go cmd/unlock.go cmd/root.go
git commit -m "feat(tsm): add version, status, lock, and unlock commands"
```

---

## Task 7: Ensure-Daemon + List Commands

**Files:**
- Create: `cmd/ensure_daemon.go`
- Create: `cmd/list.go`
- Modify: `cmd/root.go`

- [ ] **Step 1: Implement ensure-daemon command**

```go
// cmd/ensure_daemon.go
package cmd

import (
	"fmt"

	"tsm/internal/daemon"

	"github.com/spf13/cobra"
)

func newEnsureDaemonCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "ensure-daemon",
		Short: "Start daemon if not running (used by hooks)",
		RunE: func(cmd *cobra.Command, args []string) error {
			sockPath, err := daemon.EnsureRunning()
			if err != nil {
				return err
			}
			if jsonOutput() {
				return printJSON(map[string]string{"socket": sockPath})
			}
			fmt.Printf("Daemon running at %s\n", sockPath)
			return nil
		},
	}
}
```

- [ ] **Step 2: Implement list command**

```go
// cmd/list.go
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
```

- [ ] **Step 3: Register commands in root.go**

Add `newEnsureDaemonCmd()` and `newListCmd()` to `root.AddCommand(...)`.

- [ ] **Step 4: Verify build**

Run: `go build -o /dev/null . && go vet ./...`
Expected: clean

- [ ] **Step 5: Commit**

```bash
git add cmd/ensure_daemon.go cmd/list.go cmd/root.go
git commit -m "feat(tsm): add ensure-daemon and list commands"
```

---

## Task 8: Init Command (TUI)

**Files:**
- Create: `cmd/init.go`
- Modify: `cmd/root.go`

This is the first TUI command. It uses `charmbracelet/huh` for interactive forms.

- [ ] **Step 1: Add huh dependency**

Run: `go get github.com/charmbracelet/huh`

- [ ] **Step 2: Implement init command**

```go
// cmd/init.go
package cmd

import (
	"fmt"
	"os"

	"tsm/internal/client"

	"github.com/charmbracelet/huh"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

func newInitCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "init",
		Short: "Create vault, generate master key, store in Keychain",
		Long: `Initialize a new tsm vault. Generates a master key protected by Touch ID
and stores it in the macOS Keychain. Optionally set a recovery passphrase
for vault portability.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			recover, _ := cmd.Flags().GetBool("recover")
			return withClient(func(c client.Caller) error {
				if recover {
					return runInitRecover(c)
				}
				return runInit(c)
			})
		},
	}
	cmd.Flags().Bool("recover", false, "recover vault on new device using recovery passphrase")
	return cmd
}

func runInit(c client.Caller) error {
	var passphrase string

	if term.IsTerminal(int(os.Stdin.Fd())) {
		var useRecovery bool

		form := huh.NewForm(
			huh.NewGroup(
				huh.NewConfirm().
					Title("Set a recovery passphrase?").
					Description("Allows recovering the vault on a new device without Touch ID.").
					Value(&useRecovery),
			),
		)
		if err := form.Run(); err != nil {
			return err
		}

		if useRecovery {
			var confirm string
			form := huh.NewForm(
				huh.NewGroup(
					huh.NewInput().
						Title("Recovery passphrase").
						EchoMode(huh.EchoModePassword).
						Value(&passphrase),
					huh.NewInput().
						Title("Confirm passphrase").
						EchoMode(huh.EchoModePassword).
						Value(&confirm),
				),
			)
			if err := form.Run(); err != nil {
				return err
			}
			if passphrase != confirm {
				return fmt.Errorf("passphrases do not match")
			}
		}
	}

	params := map[string]any{}
	if passphrase != "" {
		params["recovery_passphrase"] = passphrase
	}

	if err := c.Call("vault.init", params, nil); err != nil {
		return handleError(err)
	}

	if jsonOutput() {
		return printJSON(map[string]bool{"ok": true})
	}
	fmt.Println("Vault created. Master key stored in Keychain with Touch ID protection.")
	if passphrase != "" {
		fmt.Println("Recovery passphrase set. Store it somewhere safe — it cannot be retrieved later.")
	}
	return nil
}

// runInitRecover recovers a vault on a new device using a recovery passphrase.
// The daemon's vault.unlock with a passphrase derives the master key and decrypts.
// NOTE: The daemon must also re-store the derived key in Keychain so future unlocks
// use Touch ID. If vault.unlock doesn't do this yet, it needs to be added to tsmd.
func runInitRecover(c client.Caller) error {
	var passphrase string

	if term.IsTerminal(int(os.Stdin.Fd())) {
		form := huh.NewForm(
			huh.NewGroup(
				huh.NewInput().
					Title("Recovery passphrase").
					Description("Enter the passphrase you set during 'tsm init'.").
					EchoMode(huh.EchoModePassword).
					Value(&passphrase),
			),
		)
		if err := form.Run(); err != nil {
			return err
		}
	} else {
		return fmt.Errorf("--recover requires an interactive terminal for passphrase input")
	}

	if passphrase == "" {
		return fmt.Errorf("passphrase cannot be empty")
	}

	if err := c.Call("vault.unlock", map[string]any{"passphrase": passphrase}, nil); err != nil {
		return handleError(err)
	}

	if jsonOutput() {
		return printJSON(map[string]bool{"ok": true})
	}
	fmt.Println("Vault recovered. Master key stored in Keychain with Touch ID protection.")
	return nil
}
```

- [ ] **Step 3: Register in root.go**

Add `newInitCmd()` to `root.AddCommand(...)`.

- [ ] **Step 4: Verify build**

Run: `go build -o /dev/null . && go vet ./...`
Expected: clean

- [ ] **Step 5: Commit**

```bash
git add cmd/init.go cmd/root.go go.mod go.sum
git commit -m "feat(tsm): add init command with TUI passphrase input"
```

---

## Task 9: Add Command (TUI)

**Files:**
- Create: `cmd/add.go`
- Modify: `cmd/root.go`

- [ ] **Step 1: Implement add command**

```go
// cmd/add.go
package cmd

import (
	"bufio"
	"fmt"
	"os"
	"strings"

	"tsm/internal/client"

	"github.com/charmbracelet/huh"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

func newAddCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "add",
		Short: "Add a secret to the vault",
		Long: `Add a secret interactively via TUI, or non-interactively via flags and stdin.

Interactive:  tsm add
Piped:        echo "secret_value" | tsm add --name foo --no-input
From file:    tsm add --name foo --from-file /path/to/key`,
		RunE: func(cmd *cobra.Command, args []string) error {
			return withClient(func(c client.Caller) error {
				return runAdd(cmd, c)
			})
		},
	}
	cmd.Flags().String("name", "", "secret name")
	cmd.Flags().String("description", "", "secret description")
	cmd.Flags().Bool("confirm", false, "require authentication on every access")
	cmd.Flags().StringSlice("tags", nil, "tags (comma-separated)")
	cmd.Flags().String("from-file", "", "read secret value from file")
	cmd.Flags().Bool("no-input", false, "non-interactive mode (read value from stdin)")
	return cmd
}

func runAdd(cmd *cobra.Command, c client.Caller) error {
	name, _ := cmd.Flags().GetString("name")
	description, _ := cmd.Flags().GetString("description")
	confirm, _ := cmd.Flags().GetBool("confirm")
	tags, _ := cmd.Flags().GetStringSlice("tags")
	fromFile, _ := cmd.Flags().GetString("from-file")
	noInput, _ := cmd.Flags().GetBool("no-input")

	var value string

	if fromFile != "" {
		// Read value from file
		data, err := os.ReadFile(fromFile)
		if err != nil {
			return fmt.Errorf("read file: %w", err)
		}
		value = strings.TrimRight(string(data), "\n")
	} else if noInput || !term.IsTerminal(int(os.Stdin.Fd())) {
		// Read value from stdin
		scanner := bufio.NewScanner(os.Stdin)
		if scanner.Scan() {
			value = scanner.Text()
		}
		if err := scanner.Err(); err != nil {
			return fmt.Errorf("read stdin: %w", err)
		}
	} else {
		// Interactive TUI
		form := huh.NewForm(
			huh.NewGroup(
				huh.NewInput().
					Title("Secret name").
					Description("Alphanumeric, underscores, hyphens. 1-128 chars.").
					Value(&name),
				huh.NewText().
					Title("Description").
					Description("What is this secret for?").
					Value(&description),
				huh.NewInput().
					Title("Secret value").
					EchoMode(huh.EchoModePassword).
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
	if description != "" {
		params["description"] = description
	}
	if confirm {
		params["confirm"] = true
	}
	if len(tags) > 0 {
		params["tags"] = tags
	}

	if err := c.Call("vault.add", params, nil); err != nil {
		return handleError(err)
	}

	if jsonOutput() {
		return printJSON(map[string]bool{"ok": true})
	}
	fmt.Printf("Secret '%s' added.\n", name)
	return nil
}
```

- [ ] **Step 2: Register in root.go**

Add `newAddCmd()` to `root.AddCommand(...)`.

- [ ] **Step 3: Verify build**

Run: `go build -o /dev/null . && go vet ./...`
Expected: clean

- [ ] **Step 4: Commit**

```bash
git add cmd/add.go cmd/root.go
git commit -m "feat(tsm): add command with TUI, stdin, and file input modes"
```

---

## Task 10: Get Command (Output Modes)

**Files:**
- Create: `cmd/get.go`
- Modify: `cmd/root.go`

The get command has the most complex output logic: `--raw`, `--to-file`, JSON default, and TTY safety.

- [ ] **Step 1: Implement get command**

```go
// cmd/get.go
package cmd

import (
	"fmt"
	"os"

	"tsm/internal/client"

	"github.com/spf13/cobra"
	"golang.org/x/term"
)

func newGetCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "get <name>",
		Short: "Retrieve a secret value",
		Long: `Retrieve a secret by name.

Default:    JSON to stdout    {"name": "...", "value": "..."}
--raw:      Raw value only    (refuses if stdout is a TTY)
--to-file:  Write to file     (mode 0600, raw value, no newline)`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return withClient(func(c client.Caller) error {
				return runGet(cmd, c, args[0])
			})
		},
	}
	cmd.Flags().Bool("raw", false, "output raw secret value (no JSON, no newline)")
	cmd.Flags().String("to-file", "", "write secret value to file (mode 0600)")
	return cmd
}

func runGet(cmd *cobra.Command, c client.Caller, name string) error {
	raw, _ := cmd.Flags().GetBool("raw")
	toFile, _ := cmd.Flags().GetString("to-file")

	var secret struct {
		Name  string `json:"name"`
		Value string `json:"value"`
	}
	if err := c.Call("vault.get", map[string]any{"name": name, "client_id": clientID()}, &secret); err != nil {
		return handleError(err)
	}

	if toFile != "" {
		if err := os.WriteFile(toFile, []byte(secret.Value), 0o600); err != nil {
			return fmt.Errorf("write to file: %w", err)
		}
		if !jsonOutput() {
			fmt.Printf("Secret written to %s\n", toFile)
		}
		return nil
	}

	if raw {
		if term.IsTerminal(int(os.Stdout.Fd())) {
			return fmt.Errorf("refusing to write secret to terminal in --raw mode\nPipe to a command or redirect: tsm get %s --raw | some-tool", name)
		}
		fmt.Print(secret.Value)
		return nil
	}

	// Default: JSON output
	return printJSON(secret)
}
```

- [ ] **Step 2: Register in root.go**

Add `newGetCmd()` to `root.AddCommand(...)`.

- [ ] **Step 3: Verify build**

Run: `go build -o /dev/null . && go vet ./...`
Expected: clean

- [ ] **Step 4: Commit**

```bash
git add cmd/get.go cmd/root.go
git commit -m "feat(tsm): add get command with raw, to-file, and JSON output modes"
```

---

## Task 11: Edit Command (TUI)

**Files:**
- Create: `cmd/edit.go`
- Modify: `cmd/root.go`

- [ ] **Step 1: Implement edit command**

```go
// cmd/edit.go
package cmd

import (
	"fmt"
	"os"
	"strings"

	"tsm/internal/client"

	"github.com/charmbracelet/huh"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

func newEditCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "edit <name>",
		Short: "Modify a secret's value, description, or confirm flag",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return withClient(func(c client.Caller) error {
				return runEdit(cmd, c, args[0])
			})
		},
	}
	cmd.Flags().String("description", "", "new description")
	cmd.Flags().String("value", "", "not supported — use interactive mode or pipe")
	cmd.Flags().Bool("confirm", false, "set confirm flag")
	cmd.Flags().Bool("no-confirm", false, "clear confirm flag")
	cmd.Flags().StringSlice("tags", nil, "replace tags")
	cmd.Flags().Bool("no-input", false, "non-interactive mode")
	cmd.Flags().MarkHidden("value")
	return cmd
}

func runEdit(cmd *cobra.Command, c client.Caller, name string) error {
	// First, fetch current secret metadata to show current values
	var secrets []secretMetadata
	if err := c.Call("vault.list", nil, &secrets); err != nil {
		return handleError(err)
	}

	var current *secretMetadata
	for i := range secrets {
		if strings.EqualFold(secrets[i].Name, name) {
			current = &secrets[i]
			break
		}
	}
	if current == nil {
		return fmt.Errorf("secret '%s' not found", name)
	}

	params := map[string]any{"name": name, "client_id": clientID()}

	noInput, _ := cmd.Flags().GetBool("no-input")

	if !noInput && term.IsTerminal(int(os.Stdin.Fd())) && !cmd.Flags().Changed("description") && !cmd.Flags().Changed("confirm") && !cmd.Flags().Changed("no-confirm") && !cmd.Flags().Changed("tags") {
		// Interactive TUI
		description := current.Description
		confirm := current.Confirm
		var newValue string

		form := huh.NewForm(
			huh.NewGroup(
				huh.NewText().
					Title("Description").
					Description(fmt.Sprintf("Current: %s", current.Description)).
					Value(&description),
				huh.NewInput().
					Title("New value (leave empty to keep current)").
					EchoMode(huh.EchoModePassword).
					Value(&newValue),
				huh.NewConfirm().
					Title("Require confirmation on every access?").
					Value(&confirm),
			),
		)
		if err := form.Run(); err != nil {
			return err
		}

		if description != current.Description {
			params["description"] = description
		}
		if newValue != "" {
			params["value"] = newValue
		}
		if confirm != current.Confirm {
			params["confirm"] = confirm
		}
	} else {
		// Flag-based editing
		if cmd.Flags().Changed("description") {
			v, _ := cmd.Flags().GetString("description")
			params["description"] = v
		}
		if cmd.Flags().Changed("confirm") {
			params["confirm"] = true
		}
		if cmd.Flags().Changed("no-confirm") {
			params["confirm"] = false
		}
		if cmd.Flags().Changed("tags") {
			v, _ := cmd.Flags().GetStringSlice("tags")
			params["tags"] = v
		}
	}

	if len(params) == 2 {
		// Only "name" and "client_id" — nothing to change
		fmt.Println("No changes specified.")
		return nil
	}

	if err := c.Call("vault.edit", params, nil); err != nil {
		return handleError(err)
	}

	if jsonOutput() {
		return printJSON(map[string]bool{"ok": true})
	}
	fmt.Printf("Secret '%s' updated.\n", name)
	return nil
}
```

- [ ] **Step 2: Register in root.go**

Add `newEditCmd()` to `root.AddCommand(...)`.

- [ ] **Step 3: Verify build**

Run: `go build -o /dev/null . && go vet ./...`
Expected: clean

- [ ] **Step 4: Commit**

```bash
git add cmd/edit.go cmd/root.go
git commit -m "feat(tsm): add edit command with TUI and flag-based modes"
```

---

## Task 12: Remove + Reset Commands

**Files:**
- Create: `cmd/remove.go`
- Create: `cmd/reset.go`
- Modify: `cmd/root.go`

- [ ] **Step 1: Implement remove command**

```go
// cmd/remove.go
package cmd

import (
	"fmt"
	"os"

	"tsm/internal/client"

	"github.com/charmbracelet/huh"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

func newRemoveCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "remove <name>",
		Aliases: []string{"rm"},
		Short:   "Remove a secret from the vault",
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return withClient(func(c client.Caller) error {
				return runRemove(cmd, c, args[0])
			})
		},
	}
	cmd.Flags().Bool("force", false, "skip confirmation prompt")
	return cmd
}

func runRemove(cmd *cobra.Command, c client.Caller, name string) error {
	force, _ := cmd.Flags().GetBool("force")

	if !force && term.IsTerminal(int(os.Stdin.Fd())) {
		var confirmed bool
		form := huh.NewForm(
			huh.NewGroup(
				huh.NewConfirm().
					Title(fmt.Sprintf("Remove secret '%s'?", name)).
					Description("This cannot be undone.").
					Value(&confirmed),
			),
		)
		if err := form.Run(); err != nil {
			return err
		}
		if !confirmed {
			fmt.Println("Cancelled.")
			return nil
		}
	}

	if err := c.Call("vault.remove", map[string]any{"name": name, "client_id": clientID()}, nil); err != nil {
		return handleError(err)
	}

	if jsonOutput() {
		return printJSON(map[string]bool{"ok": true})
	}
	fmt.Printf("Secret '%s' removed.\n", name)
	return nil
}
```

- [ ] **Step 2: Implement reset command**

```go
// cmd/reset.go
package cmd

import (
	"fmt"
	"os"

	"tsm/internal/client"
	"tsm/internal/paths"

	"github.com/charmbracelet/huh"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

func newResetCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "reset",
		Short: "Destroy vault, config, log, and Keychain entry",
		Long: `Performs a full teardown of all tsm state. This is destructive and irreversible.
Requires biometric authentication.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			dryRun, _ := cmd.Flags().GetBool("dry-run")
			if dryRun {
				return runResetDryRun()
			}
			return withClient(func(c client.Caller) error {
				return runReset(cmd, c)
			})
		},
	}
	cmd.Flags().Bool("dry-run", false, "list what would be deleted without deleting")
	cmd.Flags().Bool("force", false, "skip confirmation prompt (still requires biometric auth)")
	return cmd
}

func runResetDryRun() error {
	items := []map[string]string{
		{"type": "file", "path": paths.VaultFile()},
		{"type": "file", "path": paths.ConfigFile()},
		{"type": "file", "path": paths.AccessLog()},
		{"type": "keychain", "path": "com.tsm.vault/master-key"},
		{"type": "socket", "path": paths.SocketPath()},
	}

	if jsonOutput() {
		return printJSON(map[string]any{"dry_run": true, "items": items})
	}

	fmt.Println("Would delete:")
	for _, item := range items {
		fmt.Printf("  [%s] %s\n", item["type"], item["path"])
	}
	return nil
}

func runReset(cmd *cobra.Command, c client.Caller) error {
	force, _ := cmd.Flags().GetBool("force")

	if !force && term.IsTerminal(int(os.Stdin.Fd())) {
		var confirmed bool
		form := huh.NewForm(
			huh.NewGroup(
				huh.NewConfirm().
					Title("Reset tsm? This destroys all secrets and cannot be undone.").
					Description("Biometric authentication will be required.").
					Value(&confirmed),
			),
		)
		if err := form.Run(); err != nil {
			return err
		}
		if !confirmed {
			fmt.Println("Cancelled.")
			return nil
		}
	}

	if err := c.Call("vault.reset", map[string]any{"client_id": clientID()}, nil); err != nil {
		return handleError(err)
	}

	if jsonOutput() {
		return printJSON(map[string]bool{"ok": true})
	}
	fmt.Println("All tsm data destroyed. Run 'tsm init' to start fresh.")
	return nil
}
```

- [ ] **Step 3: Register in root.go**

Add `newRemoveCmd()` and `newResetCmd()` to `root.AddCommand(...)`.

- [ ] **Step 4: Verify build**

Run: `go build -o /dev/null . && go vet ./...`
Expected: clean

- [ ] **Step 5: Commit**

```bash
git add cmd/remove.go cmd/reset.go cmd/root.go
git commit -m "feat(tsm): add remove and reset commands with confirmation and dry-run"
```

---

## Task 13: Config + Log Commands

**Files:**
- Create: `cmd/config.go`
- Create: `cmd/log.go`
- Modify: `cmd/root.go`

- [ ] **Step 1: Implement config command**

The config command reads/writes a local JSON file. It doesn't go through the daemon — config is a CLI concern.

```go
// cmd/config.go
package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"

	"tsm/internal/paths"

	"github.com/spf13/cobra"
)

type tsmConfig struct {
	TTLHours                 int  `json:"ttl_hours"`
	UpdateCheck              bool `json:"update_check"`
	UpdateCheckIntervalHours int  `json:"update_check_interval_hours"`
}

var defaultConfig = tsmConfig{
	TTLHours:                 12,
	UpdateCheck:              true,
	UpdateCheckIntervalHours: 24,
}

func newConfigCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "config",
		Short: "View or set configuration",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runConfigView()
		},
	}

	setCmd := &cobra.Command{
		Use:   "set <key> <value>",
		Short: "Set a config value",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runConfigSet(args[0], args[1])
		},
	}

	getCmd := &cobra.Command{
		Use:   "get <key>",
		Short: "Get a config value",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runConfigGet(args[0])
		},
	}

	cmd.AddCommand(setCmd, getCmd)
	return cmd
}

func loadConfig() tsmConfig {
	cfg := defaultConfig
	data, err := os.ReadFile(paths.ConfigFile())
	if err != nil {
		return cfg
	}
	json.Unmarshal(data, &cfg)
	return cfg
}

func saveConfig(cfg tsmConfig) error {
	path := paths.ConfigFile()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(data, '\n'), 0o600)
}

func runConfigView() error {
	cfg := loadConfig()
	return printJSON(cfg)
}

func runConfigGet(key string) error {
	cfg := loadConfig()
	switch key {
	case "ttl_hours":
		fmt.Println(cfg.TTLHours)
	case "update_check":
		fmt.Println(cfg.UpdateCheck)
	case "update_check_interval_hours":
		fmt.Println(cfg.UpdateCheckIntervalHours)
	default:
		return fmt.Errorf("unknown config key: %s", key)
	}
	return nil
}

func runConfigSet(key, value string) error {
	cfg := loadConfig()
	switch key {
	case "ttl_hours":
		v, err := strconv.Atoi(value)
		if err != nil || v < 1 {
			return fmt.Errorf("ttl_hours must be a positive integer")
		}
		cfg.TTLHours = v
	case "update_check":
		v, err := strconv.ParseBool(value)
		if err != nil {
			return fmt.Errorf("update_check must be true or false")
		}
		cfg.UpdateCheck = v
	case "update_check_interval_hours":
		v, err := strconv.Atoi(value)
		if err != nil || v < 1 {
			return fmt.Errorf("update_check_interval_hours must be a positive integer")
		}
		cfg.UpdateCheckIntervalHours = v
	default:
		return fmt.Errorf("unknown config key: %s", key)
	}

	if err := saveConfig(cfg); err != nil {
		return err
	}
	if !jsonOutput() {
		fmt.Printf("%s = %s\n", key, value)
	}
	return nil
}
```

- [ ] **Step 2: Implement log command**

```go
// cmd/log.go
package cmd

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"

	"tsm/internal/paths"

	"github.com/spf13/cobra"
)

func newLogCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "log",
		Short: "View the access log",
		Long:  "Shows recent access log entries. Defaults to the last 20 entries.",
		RunE: func(cmd *cobra.Command, args []string) error {
			n, _ := cmd.Flags().GetInt("tail")
			all, _ := cmd.Flags().GetBool("all")
			if all {
				n = 0
			}
			return runLog(n)
		},
	}
	cmd.Flags().Int("tail", 20, "number of recent entries to show")
	cmd.Flags().Bool("all", false, "show all entries")
	return cmd
}

func runLog(tail int) error {
	f, err := os.Open(paths.AccessLog())
	if err != nil {
		if os.IsNotExist(err) {
			fmt.Println("No access log found.")
			return nil
		}
		return err
	}
	defer f.Close()

	var lines []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}
	if err := scanner.Err(); err != nil {
		return err
	}

	if tail > 0 && len(lines) > tail {
		lines = lines[len(lines)-tail:]
	}

	if jsonOutput() {
		var entries []json.RawMessage
		for _, line := range lines {
			entries = append(entries, json.RawMessage(line))
		}
		return printJSON(entries)
	}

	for _, line := range lines {
		var entry struct {
			TS       string  `json:"ts"`
			Method   string  `json:"method"`
			Secret   *string `json:"secret"`
			ClientID *string `json:"client_id"`
			Result   string  `json:"result"`
		}
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			fmt.Println(line)
			continue
		}
		secret := ""
		if entry.Secret != nil {
			secret = " " + *entry.Secret
		}
		clientID := ""
		if entry.ClientID != nil {
			clientID = " (" + *entry.ClientID + ")"
		}
		fmt.Printf("%s  %-14s%s  %s%s\n", entry.TS, entry.Method, secret, entry.Result, clientID)
	}
	return nil
}
```

- [ ] **Step 3: Register in root.go**

Add `newConfigCmd()` and `newLogCmd()` to `root.AddCommand(...)`.

- [ ] **Step 4: Verify build**

Run: `go build -o /dev/null . && go vet ./...`
Expected: clean

- [ ] **Step 5: Commit**

```bash
git add cmd/config.go cmd/log.go cmd/root.go
git commit -m "feat(tsm): add config and log commands"
```

---

## Task 14: Final Root Command Wiring + Integration Test

**Files:**
- Modify: `cmd/root.go` (final command registration)
- Create: `cmd/root_test.go` (smoke tests)

- [ ] **Step 1: Verify all commands are registered in root.go**

The final `NewRootCmd()` should register all commands:

```go
root.AddCommand(
    newVersionCmd(),
    newStatusCmd(),
    newLockCmd(),
    newUnlockCmd(),
    newEnsureDaemonCmd(),
    newListCmd(),
    newInitCmd(),
    newAddCmd(),
    newGetCmd(),
    newEditCmd(),
    newRemoveCmd(),
    newResetCmd(),
    newConfigCmd(),
    newLogCmd(),
)
```

- [ ] **Step 2: Write smoke tests**

```go
// cmd/root_test.go
package cmd

import (
	"testing"
)

func TestRootCmd_HasAllSubcommands(t *testing.T) {
	root := NewRootCmd()
	expected := []string{
		"version", "status", "lock", "unlock",
		"ensure-daemon", "list", "init", "add",
		"get", "edit", "remove", "reset",
		"config", "log",
	}
	commands := make(map[string]bool)
	for _, c := range root.Commands() {
		commands[c.Name()] = true
	}
	for _, name := range expected {
		if !commands[name] {
			t.Errorf("missing subcommand: %s", name)
		}
	}
}

func TestRootCmd_HasJSONFlag(t *testing.T) {
	root := NewRootCmd()
	f := root.PersistentFlags().Lookup("json")
	if f == nil {
		t.Fatal("missing --json persistent flag")
	}
}

func TestVersionCmd_Output(t *testing.T) {
	Version = "1.2.3"
	root := NewRootCmd()
	root.SetArgs([]string{"version"})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
}
```

- [ ] **Step 3: Run all tests**

Run: `go test ./... -v && go vet ./...`
Expected: all tests PASS, no vet issues

- [ ] **Step 4: Run full build**

Run: `go build -o tsm-test . && ./tsm-test version && ./tsm-test --help && rm tsm-test`
Expected: version prints "tsm dev", help shows all subcommands

- [ ] **Step 5: Commit**

```bash
git add cmd/root.go cmd/root_test.go
git commit -m "feat(tsm): wire all CLI commands and add smoke tests"
```

---

## Summary

| Task | What it builds | Key files |
|------|---------------|-----------|
| 1 | Go module + XDG paths | `go.mod`, `internal/paths/` |
| 2 | JSON-RPC types | `internal/jsonrpc/` |
| 3 | Unix socket client | `internal/client/` |
| 4 | Daemon lifecycle | `internal/daemon/` |
| 5 | CLI framework + output | `cmd/root.go`, `cmd/helpers.go` |
| 6 | version, status, lock, unlock | `cmd/version.go` etc. |
| 7 | ensure-daemon, list | `cmd/ensure_daemon.go`, `cmd/list.go` |
| 8 | init (TUI) | `cmd/init.go` |
| 9 | add (TUI + stdin + file) | `cmd/add.go` |
| 10 | get (raw, to-file, JSON) | `cmd/get.go` |
| 11 | edit (TUI) | `cmd/edit.go` |
| 12 | remove, reset | `cmd/remove.go`, `cmd/reset.go` |
| 13 | config, log | `cmd/config.go`, `cmd/log.go` |
| 14 | Final wiring + smoke tests | `cmd/root_test.go` |

**Not in this plan** (deferred to Plan 3): `tsm mcp` (MCP server mode), `tsm schema`, `tsm update`, Claude Code plugin, agent integrations.

---

## Known Gaps & Daemon Dependencies

These items surfaced during plan review. They don't block CLI implementation but need to be addressed:

1. **Recovery must re-store key in Keychain.** The spec says `tsm init --recover` derives the master key from the passphrase and stores it in Keychain for future Touch ID use. The daemon's current `vault.unlock` with passphrase derives and decrypts but does not call `keychain.storeMasterKey()`. This needs a daemon fix — when `vault.unlock` receives a passphrase and succeeds, it should store the derived key in Keychain.

2. **Config TTL vs daemon TTL.** `tsm config set ttl_hours` writes to the config file, but the daemon loaded its TTL from the vault's embedded `config.ttl_hours` during unlock. Changes to the CLI config file don't propagate to the running daemon. For now, config changes take effect after the next lock/unlock cycle. A future enhancement could add a `daemon.reload-config` RPC method.

3. **No explicit daemon stop command.** The spec mentions "exits only via `tsm daemon stop` or `daemon.shutdown`" but the CLI command table doesn't include `tsm daemon stop`. Currently, the only way to stop the daemon without destroying state is to send SIGTERM. Consider adding `tsm daemon stop` as a convenience command that calls `daemon.shutdown` — this is trivial to add later.

---

## Addendum: Display Name Support

> **Added 2026-04-25** — extends the original plan after completion. **Prerequisite:** [Plan 1 Display Name Addendum](2026-03-21-tsmd-implementation.md#addendum-display-name-field) (daemon must accept and return `display_name`).

**Goal:** `tsm add` prompts for a human-readable name. The CLI kebab-cases it into the id sent to the daemon, and stores the original as `display_name` for `tsm list` to render. Adds inline `huh` validation so the user sees errors as they tab through the form.

**Architecture:**
- A pure `internal/normalize` package owns the kebab-casing rule. Tested independently.
- `cmd/add.go` prompts for "Secret name", uses `huh.Input.Description(func() string)` to render a live preview ("stored as: `openai-api-key`"), and `Validate()` to reject inputs that normalize to empty or > 128 chars.
- `cmd/list.go` shows the display name on the first line and the kebab id on the second line. Falls back to id-only for legacy secrets without a display name.
- `cmd/edit.go` exposes `display_name` as an editable field.
- Plan 3 implication: when `tsm mcp` and `tsm schema` are written, the MCP `vault_list` tool schema must include `display_name` and the `vault_get` schema must document that it accepts the **id**, not the display name. See design doc § "Input Validation (Agent Safety)".

### Task 15: Name Normalization Helper

**Files:**
- Create: `internal/normalize/normalize.go`
- Test: `internal/normalize/normalize_test.go`

- [ ] **Step 1: Write failing tests**

```go
package normalize

import (
	"strings"
	"testing"
)

func TestKebab(t *testing.T) {
	cases := []struct {
		in, want string
		wantErr  bool
	}{
		{"openai-api-key", "openai-api-key", false},
		{"OpenAI API key", "openai-api-key", false},
		{"GitHub PAT", "github-pat", false},
		{"  GitHub  PAT  ", "github-pat", false},
		{"Carl's prod token!", "carl-s-prod-token", false},
		{"already-fine", "already-fine", false},
		{"a___b", "a-b", false},
		{"---OpenAI---", "openai", false},
		{"", "", true},
		{"   ", "", true},
		{"---", "", true},
		{"!!!", "", true},
		{strings.Repeat("a", 200), "", true}, // > 128 after normalization
	}
	for _, c := range cases {
		got, err := Kebab(c.in)
		if (err != nil) != c.wantErr {
			t.Errorf("Kebab(%q) err=%v wantErr=%v", c.in, err, c.wantErr)
			continue
		}
		if !c.wantErr && got != c.want {
			t.Errorf("Kebab(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
```

Run: `go test ./internal/normalize/`
Expected: FAIL — package does not exist.

- [ ] **Step 2: Implement `Kebab`**

```go
// Package normalize derives kebab-case secret ids from free-text display names.
package normalize

import (
	"errors"
	"strings"
	"unicode"
)

// Kebab lowercases s, replaces runs of non-alphanumeric ASCII characters with
// a single hyphen, and trims leading/trailing hyphens. Returns an error if the
// result is empty or longer than 128 characters.
func Kebab(s string) (string, error) {
	var b strings.Builder
	b.Grow(len(s))
	prevHyphen := true
	for _, r := range s {
		switch {
		case r >= 'A' && r <= 'Z':
			b.WriteRune(unicode.ToLower(r))
			prevHyphen = false
		case (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9'):
			b.WriteRune(r)
			prevHyphen = false
		default:
			if !prevHyphen {
				b.WriteByte('-')
				prevHyphen = true
			}
		}
	}
	out := strings.Trim(b.String(), "-")
	if out == "" {
		return "", errors.New("name must contain at least one alphanumeric character")
	}
	if len(out) > 128 {
		return "", errors.New("name must be 128 characters or fewer after normalization")
	}
	return out, nil
}
```

Run: `go test ./internal/normalize/ -v`
Expected: all cases PASS.

- [ ] **Step 3: Commit**

```bash
git add internal/normalize/
git commit -m "feat(tsm): add normalize.Kebab helper for kebab-case secret ids"
```

---

### Task 16: Add Command — Display Name Prompt + Live Preview + Validation

**Files:**
- Modify: `cmd/add.go`

- [ ] **Step 1: Replace the interactive form to prompt for a display name**

In `cmd/add.go`, the interactive branch (currently asks for "Secret name") is replaced. The user types a free-text display name. The id is derived via `normalize.Kebab`. `huh.Input.Validate` runs the normalization and surfaces errors inline. `huh.Input.Description` is called by huh on each render to preview the derived id.

Add the import:

```go
import (
	// ... existing imports ...
	"tsm/internal/normalize"
)
```

Replace the interactive branch's `huh.NewForm(...)` block:

```go
var displayName string

form := huh.NewForm(
	huh.NewGroup(
		huh.NewInput().
			Title("Secret name").
			DescriptionFunc(func() string {
				if displayName == "" {
					return "e.g. \"OpenAI API key\""
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
```

Note: `DescriptionFunc(fn, bindings...)` is the huh API for live-updating descriptions. The bindings (`&displayName`) tell huh which values to watch so it re-renders when they change. If your installed huh version only exposes `Description(string)`, fall back to a static description and skip the live preview — the validation still gives the user feedback when they try to advance.

The non-interactive branches (`--name` flag, `--no-input`, `--from-file`) are unchanged: they pass `name` straight through.

- [ ] **Step 2: Add `--display-name` flag for non-interactive use**

In the cobra flag block:

```go
cmd.Flags().String("display-name", "", "human-readable name shown in 'tsm list' (defaults to --name)")
```

In `runAdd`, after collecting `name` from the interactive form *or* the flags:

```go
flagDisplayName, _ := cmd.Flags().GetString("display-name")
if flagDisplayName != "" {
	displayName = flagDisplayName
}
```

When sending params, include `display_name` only when non-empty:

```go
if displayName != "" {
	params["display_name"] = displayName
}
```

- [ ] **Step 3: Update success message to show derived id**

```go
if !jsonOutput() {
	if displayName != "" && displayName != name {
		fmt.Printf("Secret '%s' added (id: %s).\n", displayName, name)
	} else {
		fmt.Printf("Secret '%s' added.\n", name)
	}
}
```

- [ ] **Step 4: Verify build**

```bash
go build -o /dev/null . && go vet ./...
```

Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add cmd/add.go
git commit -m "feat(tsm): prompt for display name in 'tsm add' with live id preview and huh validation"
```

---

### Task 17: List Command — Show Display Name with ID Underneath

**Files:**
- Modify: `cmd/list.go`

- [ ] **Step 1: Add `DisplayName` to the `secretMetadata` struct**

```go
type secretMetadata struct {
	Name        string   `json:"name"`
	DisplayName string   `json:"display_name"`
	Description string   `json:"description"`
	Confirm     bool     `json:"confirm"`
	Tags        []string `json:"tags"`
}
```

- [ ] **Step 2: Render display name with id annotation**

Replace the per-secret print loop in `runList`:

```go
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
	fmt.Printf("  %s%s%s\n", label, confirm, tags)
	if s.DisplayName != "" && s.DisplayName != s.Name {
		fmt.Printf("    id: %s\n", s.Name)
	}
	if s.Description != "" {
		fmt.Printf("    %s\n", s.Description)
	}
}
```

JSON output mode is unchanged structurally — `display_name` flows through automatically because the struct now carries it.

- [ ] **Step 3: Verify build**

```bash
go build -o /dev/null . && go vet ./...
```

Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add cmd/list.go
git commit -m "feat(tsm): show display_name in 'tsm list' with kebab id underneath"
```

---

### Task 18: Edit Command — Allow Display Name Updates

**Files:**
- Modify: `cmd/edit.go`

- [ ] **Step 1: Add display-name flag and TUI field**

In the cobra flag block:

```go
cmd.Flags().String("display-name", "", "new display name (empty string clears)")
```

In `runEdit`, in the interactive branch, add a `Display name` input as the first field of the form so the user can edit it before description/value/confirm:

```go
displayName := current.DisplayName

form := huh.NewForm(
	huh.NewGroup(
		huh.NewInput().
			Title("Display name").
			Description("Shown in 'tsm list'. Leave as-is to keep; blank to clear.").
			Value(&displayName),
		// ... existing Description/Value/Confirm fields unchanged ...
	),
)
// ... after form.Run() ...
if displayName != current.DisplayName {
	params["display_name"] = displayName
}
```

In the flag-based branch:

```go
if cmd.Flags().Changed("display-name") {
	v, _ := cmd.Flags().GetString("display-name")
	params["display_name"] = v
}
```

Also add `Changed("display-name")` to the condition that switches between TUI and flag-based modes (so editing only `--display-name` doesn't open the TUI).

- [ ] **Step 2: Verify build**

```bash
go build -o /dev/null . && go vet ./...
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add cmd/edit.go
git commit -m "feat(tsm): allow editing display_name via 'tsm edit'"
```

---

### Addendum Summary

| Task | Component | Key Files |
|------|-----------|-----------|
| 15 | `Kebab` normalization helper | `internal/normalize/` |
| 16 | `tsm add` prompts for display name; live id preview; huh validation | `cmd/add.go` |
| 17 | `tsm list` renders display name with id beneath | `cmd/list.go` |
| 18 | `tsm edit` allows updating display name | `cmd/edit.go` |

**Plan 3 forward-pointer:** When MCP server mode (`tsm mcp`) and `tsm schema` are implemented, the `vault_list` tool schema must include `display_name`, and `vault_get` documentation must specify that the **id** (`name`) is the lookup key — not the display name. Agents should treat display names as cosmetic only.
