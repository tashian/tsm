package cmd

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"tsm/internal/paths"
)

func TestStatus_TextIncludesVersionAndVaultPath(t *testing.T) {
	prev := Version
	Version = "1.2.3-test"
	t.Cleanup(func() { Version = prev })

	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			if method != "vault.status" {
				return nil, errors.New("unexpected method " + method)
			}
			return map[string]any{
				"locked":       true,
				"secret_count": 7,
			}, nil
		},
	}

	var buf bytes.Buffer
	if err := runStatus(mock, &buf); err != nil {
		t.Fatal(err)
	}

	out := buf.String()
	if !strings.Contains(out, "tsm 1.2.3-test") {
		t.Errorf("output missing version line: %q", out)
	}
	if !strings.Contains(out, paths.VaultFile()) {
		t.Errorf("output missing vault path %q: %q", paths.VaultFile(), out)
	}
	if !strings.Contains(out, "Vault: locked") {
		t.Errorf("output missing locked state: %q", out)
	}
	// The daemon reports 0 secrets while locked, which reads as an empty
	// vault. Leave the count out until it is real.
	if strings.Contains(out, "Secrets:") {
		t.Errorf("locked status must not show a secret count: %q", out)
	}
}

func TestStatus_JSONOmitsSecretCountWhenLocked(t *testing.T) {
	prevJSON := jsonFlag
	jsonFlag = true
	t.Cleanup(func() { jsonFlag = prevJSON })

	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			return map[string]any{"locked": true, "secret_count": 0}, nil
		},
	}
	var buf bytes.Buffer
	if err := runStatus(mock, &buf); err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(buf.Bytes(), &got); err != nil {
		t.Fatalf("invalid JSON: %s", buf.String())
	}
	if _, ok := got["secret_count"]; ok {
		t.Errorf("locked status must omit secret_count: %s", buf.String())
	}
}

func TestStatus_TextShowsSecretCountWhenUnlocked(t *testing.T) {
	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			return map[string]any{"locked": false, "secret_count": 7, "ttl_remaining_seconds": 60}, nil
		},
	}
	var buf bytes.Buffer
	if err := runStatus(mock, &buf); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(buf.String(), "Secrets: 7") {
		t.Errorf("output missing secret count: %q", buf.String())
	}
}

func TestStatus_JSONIncludesVersionAndVaultPath(t *testing.T) {
	prev := Version
	Version = "9.9.9"
	t.Cleanup(func() { Version = prev })

	prevJSON := jsonFlag
	jsonFlag = true
	t.Cleanup(func() { jsonFlag = prevJSON })

	ttl := 1800
	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			return map[string]any{
				"locked":                false,
				"secret_count":          3,
				"ttl_remaining_seconds": ttl,
			}, nil
		},
	}

	var buf bytes.Buffer
	if err := runStatus(mock, &buf); err != nil {
		t.Fatal(err)
	}

	var got map[string]any
	if err := json.Unmarshal(buf.Bytes(), &got); err != nil {
		t.Fatalf("invalid JSON: %s", buf.String())
	}
	if got["version"] != "9.9.9" {
		t.Errorf("version mismatch: %v", got["version"])
	}
	if got["vault_path"] != paths.VaultFile() {
		t.Errorf("vault_path mismatch: %v", got["vault_path"])
	}
	if got["locked"] != false {
		t.Errorf("locked mismatch: %v", got["locked"])
	}
	if got["secret_count"].(float64) != 3 {
		t.Errorf("secret_count mismatch: %v", got["secret_count"])
	}
	if got["ttl_remaining_seconds"].(float64) != 1800 {
		t.Errorf("ttl mismatch: %v", got["ttl_remaining_seconds"])
	}
}
