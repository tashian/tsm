package cmd

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// addMock returns a mockCaller that ACKs vault.unlock and captures the
// vault.add params for assertions. The captured params are stored in *into.
func addMock(into *map[string]any) *mockCaller {
	return &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			switch method {
			case "vault.unlock":
				return nil, nil
			case "vault.add":
				if into != nil {
					*into = params
				}
				return nil, nil
			}
			return nil, errors.New("unexpected method " + method)
		},
	}
}

func TestAdd_StdinPipe(t *testing.T) {
	var captured map[string]any
	mock := addMock(&captured)
	var stdout bytes.Buffer
	err := runAddWith(mock, addOptions{
		Name:        "openai-key-foo",
		DisplayName: "OpenAI API Key (foo)",
		Description: "Swept from .env",
		Stdin:       strings.NewReader("sk-proj-abc123\n"),
		StdinTTY:    false,
		Stdout:      &stdout,
	})
	if err != nil {
		t.Fatal(err)
	}
	if captured["name"] != "openai-key-foo" {
		t.Errorf("name: got %v, want openai-key-foo", captured["name"])
	}
	if captured["value"] != "sk-proj-abc123" {
		t.Errorf("value: got %q, want %q (trailing newline must be trimmed)", captured["value"], "sk-proj-abc123")
	}
	if captured["display_name"] != "OpenAI API Key (foo)" {
		t.Errorf("display_name: got %v", captured["display_name"])
	}
	if captured["description"] != "Swept from .env" {
		t.Errorf("description: got %v", captured["description"])
	}
}

func TestAdd_FromFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "key.txt")
	// Trailing newline should be stripped (matching how editors save text files).
	if err := os.WriteFile(path, []byte("ghp_secret_value\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	var captured map[string]any
	mock := addMock(&captured)
	err := runAddWith(mock, addOptions{
		Name:     "gh-pat",
		FromFile: path,
		StdinTTY: true, // shouldn't matter; --from-file wins
		Stdout:   &bytes.Buffer{},
	})
	if err != nil {
		t.Fatal(err)
	}
	if captured["value"] != "ghp_secret_value" {
		t.Errorf("value: got %q, want %q", captured["value"], "ghp_secret_value")
	}
}

func TestAdd_LargeStdinValue(t *testing.T) {
	// 256KB value — exceeds bufio.Scanner's default 64KB buffer.
	// This test guards against regression to bufio.Scanner.
	const size = 256 * 1024
	big := strings.Repeat("a", size)
	var captured map[string]any
	mock := addMock(&captured)
	err := runAddWith(mock, addOptions{
		Name:     "big",
		Stdin:    strings.NewReader(big),
		StdinTTY: false,
		Stdout:   &bytes.Buffer{},
	})
	if err != nil {
		t.Fatal(err)
	}
	got, ok := captured["value"].(string)
	if !ok {
		t.Fatalf("value not a string: %T", captured["value"])
	}
	if len(got) != size {
		t.Errorf("value length: got %d, want %d (truncation suggests bufio.Scanner regression)", len(got), size)
	}
	if got != big {
		t.Errorf("value content mismatch (length ok but bytes differ)")
	}
}

func TestAdd_MultiLineStdinValue(t *testing.T) {
	// Multi-line values (PEM bundles, GCP service-account JSON) must be
	// preserved end-to-end with internal newlines intact. Only the trailing
	// newline is stripped.
	pem := "-----BEGIN PRIVATE KEY-----\nMIIEv...\nQ==\n-----END PRIVATE KEY-----\n"
	var captured map[string]any
	mock := addMock(&captured)
	err := runAddWith(mock, addOptions{
		Name:     "tls-key",
		Stdin:    strings.NewReader(pem),
		StdinTTY: false,
		Stdout:   &bytes.Buffer{},
	})
	if err != nil {
		t.Fatal(err)
	}
	want := strings.TrimRight(pem, "\n")
	if captured["value"] != want {
		t.Errorf("multi-line value not preserved.\n got: %q\nwant: %q", captured["value"], want)
	}
}

func TestAdd_RejectsValueFlag(t *testing.T) {
	// Regression guard: per CLAUDE.md, --value must NEVER be added to tsm add.
	// Flag values appear in `ps` output and shell history, leaking the secret.
	cmd := newAddCmd()
	if f := cmd.Flags().Lookup("value"); f != nil {
		t.Fatalf("tsm add must not have a --value flag (would leak secrets via ps/shell history)")
	}
	if f := cmd.Flags().Lookup("secret"); f != nil {
		t.Fatalf("tsm add must not have a --secret flag (would leak secrets via ps/shell history)")
	}
}

func TestAdd_MissingNameNonInteractive(t *testing.T) {
	mock := addMock(nil)
	err := runAddWith(mock, addOptions{
		// no Name, no DisplayName
		Stdin:    strings.NewReader("some-value"),
		StdinTTY: false,
		Stdout:   &bytes.Buffer{},
	})
	if err == nil {
		t.Fatal("expected error when --name is missing in non-interactive mode")
	}
	if !strings.Contains(err.Error(), "name") {
		t.Errorf("error should mention name, got: %v", err)
	}
}

func TestAdd_MissingValueNonInteractive(t *testing.T) {
	mock := addMock(nil)
	err := runAddWith(mock, addOptions{
		Name:     "foo",
		Stdin:    strings.NewReader(""), // empty stdin
		StdinTTY: false,
		Stdout:   &bytes.Buffer{},
	})
	if err == nil {
		t.Fatal("expected error when value is empty")
	}
	if !strings.Contains(err.Error(), "value") {
		t.Errorf("error should mention value, got: %v", err)
	}
}

func TestAdd_JSONOutput(t *testing.T) {
	prev := jsonFlag
	jsonFlag = true
	t.Cleanup(func() { jsonFlag = prev })

	mock := addMock(nil)
	var stdout bytes.Buffer
	err := runAddWith(mock, addOptions{
		Name:        "foo",
		DisplayName: "Foo Display",
		Stdin:       strings.NewReader("v"),
		StdinTTY:    false,
		Stdout:      &stdout,
	})
	if err != nil {
		t.Fatal(err)
	}
	out := stdout.String()
	// Must be machine-parseable JSON, not the human "Secret 'foo' added." line.
	if strings.Contains(out, "added") {
		t.Errorf("--json output should not contain human prose, got: %q", out)
	}
	if !strings.Contains(out, `"ok"`) {
		t.Errorf("--json output should contain ok key, got: %q", out)
	}
	if !strings.Contains(out, "true") {
		t.Errorf("--json output should report ok=true, got: %q", out)
	}
}

func TestAdd_SendsTagsAndConfirm(t *testing.T) {
	// Locks down the agent-facing wire shape: tags arrive as a slice and
	// confirm arrives as bool true (omitted when false to avoid noise).
	var captured map[string]any
	mock := addMock(&captured)
	err := runAddWith(mock, addOptions{
		Name:     "foo",
		Confirm:  true,
		Tags:     []string{"swept", "openai"},
		Stdin:    strings.NewReader("val"),
		StdinTTY: false,
		Stdout:   &bytes.Buffer{},
	})
	if err != nil {
		t.Fatal(err)
	}
	if captured["confirm"] != true {
		t.Errorf("confirm: got %v, want true", captured["confirm"])
	}
	tags, ok := captured["tags"].([]string)
	if !ok {
		t.Fatalf("tags: got type %T, want []string", captured["tags"])
	}
	if len(tags) != 2 || tags[0] != "swept" || tags[1] != "openai" {
		t.Errorf("tags: got %v", tags)
	}
}
