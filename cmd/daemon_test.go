package cmd

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

func TestDaemonStop_CallsShutdownAndPrintsConfirmation(t *testing.T) {
	var called bool
	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			if method != "daemon.shutdown" {
				return nil, errors.New("unexpected method " + method)
			}
			called = true
			return map[string]any{"ok": true}, nil
		},
	}

	var buf bytes.Buffer
	if err := runDaemonStop(mock, false, &buf); err != nil {
		t.Fatal(err)
	}
	if !called {
		t.Error("daemon.shutdown not called")
	}
	if !strings.Contains(buf.String(), "stopped") {
		t.Errorf("expected confirmation, got %q", buf.String())
	}
}

func TestDaemonStop_AlreadyDownIsIdempotent(t *testing.T) {
	var buf bytes.Buffer
	// Caller is nil because we should skip the RPC entirely when already down.
	if err := runDaemonStop(nil, true, &buf); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(buf.String(), "not running") {
		t.Errorf("expected 'not running' message, got %q", buf.String())
	}
}

func TestDaemonStop_JSONOutput(t *testing.T) {
	prev := jsonFlag
	jsonFlag = true
	t.Cleanup(func() { jsonFlag = prev })

	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			return map[string]any{"ok": true}, nil
		},
	}
	var buf bytes.Buffer
	if err := runDaemonStop(mock, false, &buf); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(buf.String(), `"stopped"`) {
		t.Errorf("expected JSON with stopped field, got %q", buf.String())
	}
}

func TestDaemonStop_AlreadyDownJSONOutput(t *testing.T) {
	prev := jsonFlag
	jsonFlag = true
	t.Cleanup(func() { jsonFlag = prev })

	var buf bytes.Buffer
	if err := runDaemonStop(nil, true, &buf); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(buf.String(), `"already_down"`) {
		t.Errorf("expected JSON with already_down field, got %q", buf.String())
	}
}
