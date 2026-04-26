package cmd

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"tsm/internal/client"
)

// mockCaller is a minimal client.Caller for testing get/run command logic.
type mockCaller struct {
	calls []mockCall
	// onCall returns the result for a given (method, params), or an error.
	// If result is non-nil and v is non-nil, the value is JSON-marshaled then
	// unmarshaled into result to mimic the daemon round-trip.
	onCall func(method string, params map[string]any) (any, error)
}

type mockCall struct {
	Method string
	Params map[string]any
}

func (m *mockCaller) Call(method string, params map[string]any, result any) error {
	m.calls = append(m.calls, mockCall{Method: method, Params: params})
	if m.onCall == nil {
		return nil
	}
	v, err := m.onCall(method, params)
	if err != nil {
		return err
	}
	if result != nil && v != nil {
		data, marshalErr := json.Marshal(v)
		if marshalErr != nil {
			return marshalErr
		}
		return json.Unmarshal(data, result)
	}
	return nil
}

func (m *mockCaller) Close() error { return nil }

func TestGet_FormatEnv_RoutesThroughFormatter(t *testing.T) {
	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			if method == "vault.unlock" {
				return nil, nil
			}
			if method == "vault.get" {
				return map[string]string{"name": "gh-pat", "value": "ghp_abc"}, nil
			}
			return nil, errors.New("unexpected method " + method)
		},
	}
	var stdout bytes.Buffer
	err := runGetWith(mock, "gh-pat", getOptions{
		Format:    "env GITHUB_TOKEN",
		Stdout:    &stdout,
		StdoutTTY: false,
	})
	if err != nil {
		t.Fatal(err)
	}
	if stdout.String() != "GITHUB_TOKEN=ghp_abc\n" {
		t.Fatalf("got %q", stdout.String())
	}
}

func TestGet_FormatRefusesTTY(t *testing.T) {
	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			return map[string]string{"name": "n", "value": "v"}, nil
		},
	}
	err := runGetWith(mock, "n", getOptions{
		Format:    "env FOO",
		Stdout:    &bytes.Buffer{},
		StdoutTTY: true,
	})
	if err == nil {
		t.Fatal("expected refusal when stdout is a TTY")
	}
	if !strings.Contains(err.Error(), "terminal") {
		t.Fatalf("error should mention terminal, got: %v", err)
	}
}

func TestGet_DefaultWritesBareValueToNonTTY(t *testing.T) {
	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			if method == "vault.unlock" {
				return nil, nil
			}
			return map[string]string{"name": "gh-pat", "value": "ghp_abc"}, nil
		},
	}
	var stdout bytes.Buffer
	err := runGetWith(mock, "gh-pat", getOptions{
		Stdout:    &stdout,
		StdoutTTY: false,
	})
	if err != nil {
		t.Fatal(err)
	}
	if stdout.String() != "ghp_abc" {
		t.Fatalf("got %q, want bare value with no framing or trailing newline", stdout.String())
	}
}

func TestGet_DefaultRefusesTTY(t *testing.T) {
	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			return map[string]string{"name": "n", "value": "v"}, nil
		},
	}
	err := runGetWith(mock, "n", getOptions{
		Stdout:    &bytes.Buffer{},
		StdoutTTY: true,
	})
	if err == nil {
		t.Fatal("expected refusal when stdout is a TTY")
	}
	if !strings.Contains(err.Error(), "terminal") {
		t.Fatalf("error should mention terminal, got: %v", err)
	}
}

func TestGet_RejectsJSONFlag(t *testing.T) {
	prev := jsonFlag
	jsonFlag = true
	t.Cleanup(func() { jsonFlag = prev })
	mock := &mockCaller{}
	err := runGetWith(mock, "n", getOptions{
		Stdout:    &bytes.Buffer{},
		StdoutTTY: false,
	})
	if err == nil {
		t.Fatal("expected --json rejection")
	}
	if !strings.Contains(err.Error(), "--json") {
		t.Fatalf("error should mention --json, got: %v", err)
	}
}

func TestGet_FormatMutexWithToFile(t *testing.T) {
	mock := &mockCaller{}
	err := runGetWith(mock, "n", getOptions{
		Format:    "env FOO",
		ToFile:    "/tmp/x",
		Stdout:    &bytes.Buffer{},
		StdoutTTY: false,
	})
	if err == nil {
		t.Fatal("expected mutex error")
	}
	if !strings.Contains(err.Error(), "--to-file") {
		t.Fatalf("error should mention --to-file, got: %v", err)
	}
}

func TestGet_FormatUnknownFormatter(t *testing.T) {
	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			return map[string]string{"name": "n", "value": "v"}, nil
		},
	}
	err := runGetWith(mock, "n", getOptions{
		Format:    "no-such-formatter",
		Stdout:    &bytes.Buffer{},
		StdoutTTY: false,
	})
	if err == nil {
		t.Fatal("expected error for unknown formatter")
	}
	if !strings.Contains(err.Error(), "no-such-formatter") {
		t.Fatalf("error should name the unknown formatter, got: %v", err)
	}
}

// Just a tiny sanity check that mockCaller records calls.
func TestMockCaller_RecordsCalls(t *testing.T) {
	m := &mockCaller{onCall: func(method string, params map[string]any) (any, error) { return nil, nil }}
	_ = m.Call("vault.unlock", nil, nil)
	_ = m.Call("vault.get", map[string]any{"name": "x"}, nil)
	if len(m.calls) != 2 {
		t.Fatalf("expected 2 calls, got %d", len(m.calls))
	}
	if m.calls[1].Method != "vault.get" {
		t.Fatalf("expected vault.get, got %s", m.calls[1].Method)
	}
}

// Ensure mockCaller satisfies client.Caller at compile time.
var _ client.Caller = (*mockCaller)(nil)
