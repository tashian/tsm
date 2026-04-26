# tsm Agent Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Plan 3 from `docs/plans/2026-04-25-tsm-agent-integration-design.md`: a `tsm run` env-var injection wrapper, `tsm get --format` output formatters, and a Claude Code plugin that ties them together via an opinionated skill.

**Architecture:** Pure CLI + plugin work on top of the existing daemon. No `tsmd` (Swift) changes, no JSON-RPC additions, no vault format changes. New Go packages `internal/format/` and `internal/runspec/`; new cobra command `cmd/run.go`; new flag on `cmd/get.go`; new top-level `plugin/` directory containing the Claude Code plugin assets.

**Tech Stack:** Go (cobra, golang.org/x/term, golang.org/x/sys/unix), JSON-RPC 2.0 over Unix socket (existing client). No new dependencies anticipated.

---

## File Structure

| File | Responsibility | Touched by tasks |
|---|---|---|
| `internal/format/format.go` | `Formatter` interface, package-level registry (`Register`, `Get`). | Task 1 |
| `internal/format/format_test.go` | Registry + interface contract tests. | Task 1 |
| `internal/format/env.go` | `env VAR` formatter. | Task 2 |
| `internal/format/env_test.go` | env formatter tests. | Task 2 |
| `internal/format/aws_credential_process.go` | `aws-credential-process` formatter. | Task 3 |
| `internal/format/aws_credential_process_test.go` | AWS formatter tests. | Task 3 |
| `internal/format/pgpass.go` | `pgpass` formatter. | Task 4 |
| `internal/format/pgpass_test.go` | pgpass formatter tests. | Task 4 |
| `cmd/get.go` | Add `--format` flag, mutex with `--raw`/`--to-file`/`--json`, dispatch to `internal/format`. | Task 5 |
| `cmd/get_test.go` (new) | Smoke tests for `--format` dispatch and mutex flag rejection. | Task 5 |
| `internal/runspec/runspec.go` | `Mapping` type and `Parse([]string) ([]Mapping, error)` for `--env VAR=secret` flag values. | Task 6 |
| `internal/runspec/runspec_test.go` | Parser tests. | Task 6 |
| `cmd/run.go` | New cobra subcommand. Resolve mappings, gate on confirm+TTY, `setenv`, `execve`. Injectable `runner` for testing. | Tasks 7, 8, 9 |
| `cmd/run_test.go` | Integration tests against mock `client.Caller`. | Tasks 7, 8, 9 |
| `cmd/root.go` | Register `newRunCmd()` in `NewRootCmd`. | Task 7 |
| `cmd/root_test.go` | Add `"run"` to expected-subcommands list. | Task 7 |
| `cmd/helpers.go` | (Optional) `runClientID(targetBasename)` helper if `clientID()` doesn't fit the new shape. | Task 9 |
| `plugin/.claude-plugin/plugin.json` | Plugin manifest. | Task 10 |
| `plugin/hooks/hooks.json` | SessionStart hook → `tsm ensure-daemon`. | Task 10 |
| `plugin/settings.json` | Permission allowlist. | Task 10 |
| `plugin/skills/credential-usage/SKILL.md` | Opinionated credential-usage skill. | Task 11 |
| `plugin/README.md` | Brief install instructions for the plugin. | Task 11 |
| `CLAUDE.md` | Add note: PRs that change CLI surface must update the plugin skill. | Task 12 |

---

## Task 1: Formatter interface and registry

**Files:**
- Create: `internal/format/format.go`
- Create: `internal/format/format_test.go`

- [ ] **Step 1: Write the failing test**

Create `internal/format/format_test.go`:

```go
package format

import (
	"errors"
	"testing"
)

type fakeFormatter struct{ out []byte }

func (f *fakeFormatter) Format(value string, args []string) ([]byte, error) {
	return f.out, nil
}

func TestRegisterAndGet(t *testing.T) {
	f := &fakeFormatter{out: []byte("hello\n")}
	Register("fake-test-1", f)
	got, ok := Get("fake-test-1")
	if !ok {
		t.Fatal("expected Get to find registered formatter")
	}
	out, err := got.Format("ignored", nil)
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != "hello\n" {
		t.Fatalf("expected hello\\n, got %q", string(out))
	}
}

func TestGet_Unknown(t *testing.T) {
	_, ok := Get("does-not-exist")
	if ok {
		t.Fatal("expected Get to return ok=false for unknown formatter")
	}
}

type errFormatter struct{}

func (errFormatter) Format(value string, args []string) ([]byte, error) {
	return nil, errors.New("boom")
}

func TestFormatter_ErrorPropagates(t *testing.T) {
	Register("fake-test-2", errFormatter{})
	f, _ := Get("fake-test-2")
	_, err := f.Format("v", nil)
	if err == nil || err.Error() != "boom" {
		t.Fatalf("expected boom, got %v", err)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/format/... -run TestRegisterAndGet -v`
Expected: FAIL with build error (`format` package does not exist).

- [ ] **Step 3: Write minimal implementation**

Create `internal/format/format.go`:

```go
// Package format provides built-in output formatters for tsm get --format.
//
// A Formatter takes a raw secret value plus optional inline arguments and
// returns the value reshaped for a specific consumer (env file line, AWS
// credential_process JSON, pgpass row, etc.).
package format

// Formatter reshapes a secret value into a wire format consumed by a
// specific tool. Implementations must not mutate the input value.
type Formatter interface {
	Format(value string, args []string) ([]byte, error)
}

var registry = map[string]Formatter{}

// Register adds a formatter under name. Last registration wins; intended to
// be called from per-formatter init() functions.
func Register(name string, f Formatter) {
	registry[name] = f
}

// Get returns the formatter registered under name and whether one exists.
func Get(name string) (Formatter, bool) {
	f, ok := registry[name]
	return f, ok
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/format/... -v`
Expected: PASS — three tests.

- [ ] **Step 5: Commit**

```bash
git add internal/format/format.go internal/format/format_test.go
git commit -m "feat(tsm): add internal/format Formatter interface and registry"
```

---

## Task 2: env formatter

**Files:**
- Create: `internal/format/env.go`
- Create: `internal/format/env_test.go`

- [ ] **Step 1: Write the failing test**

Create `internal/format/env_test.go`:

```go
package format

import (
	"strings"
	"testing"
)

func TestEnvFormatter_Basic(t *testing.T) {
	f, ok := Get("env")
	if !ok {
		t.Fatal("env formatter not registered")
	}
	out, err := f.Format("ghp_abc123", []string{"GITHUB_TOKEN"})
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != "GITHUB_TOKEN=ghp_abc123\n" {
		t.Fatalf("got %q", string(out))
	}
}

func TestEnvFormatter_RequiresOneArg(t *testing.T) {
	f, _ := Get("env")
	_, err := f.Format("v", nil)
	if err == nil {
		t.Fatal("expected error when no VAR provided")
	}
	if !strings.Contains(err.Error(), "VAR") {
		t.Fatalf("error should mention VAR, got: %v", err)
	}
	_, err = f.Format("v", []string{"A", "B"})
	if err == nil {
		t.Fatal("expected error when more than one arg provided")
	}
}

func TestEnvFormatter_RejectsBadVar(t *testing.T) {
	f, _ := Get("env")
	bad := []string{"lowercase", "1STARTS_DIGIT", "HAS-DASH", "HAS SPACE", "", "HAS.DOT"}
	for _, v := range bad {
		if _, err := f.Format("x", []string{v}); err == nil {
			t.Errorf("expected error for VAR=%q", v)
		}
	}
}

func TestEnvFormatter_AcceptsValidVar(t *testing.T) {
	f, _ := Get("env")
	good := []string{"A", "_", "_FOO", "FOO_BAR", "FOO_BAR_2", "X1"}
	for _, v := range good {
		if _, err := f.Format("x", []string{v}); err != nil {
			t.Errorf("expected ok for VAR=%q, got %v", v, err)
		}
	}
}

func TestEnvFormatter_ValuePreservedVerbatim(t *testing.T) {
	f, _ := Get("env")
	// Newlines and special chars in the value pass through unchanged.
	// (.env-file consumers vary; we don't try to escape.)
	out, _ := f.Format("a=b c\nd", []string{"X"})
	if string(out) != "X=a=b c\nd\n" {
		t.Fatalf("got %q", string(out))
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/format/... -run TestEnvFormatter -v`
Expected: FAIL — env formatter not registered.

- [ ] **Step 3: Write minimal implementation**

Create `internal/format/env.go`:

```go
package format

import (
	"fmt"
	"regexp"
)

var envVarRE = regexp.MustCompile(`^[A-Z_][A-Z0-9_]*$`)

type envFormatter struct{}

// Format emits "VAR=value\n". args must be exactly one element: VAR.
func (envFormatter) Format(value string, args []string) ([]byte, error) {
	if len(args) != 1 {
		return nil, fmt.Errorf("env formatter requires exactly one argument: VAR (got %d)", len(args))
	}
	v := args[0]
	if !envVarRE.MatchString(v) {
		return nil, fmt.Errorf("invalid env var name %q (must match [A-Z_][A-Z0-9_]*)", v)
	}
	return []byte(v + "=" + value + "\n"), nil
}

func init() {
	Register("env", envFormatter{})
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/format/... -v`
Expected: PASS — all formatter tests including env.

- [ ] **Step 5: Commit**

```bash
git add internal/format/env.go internal/format/env_test.go
git commit -m "feat(tsm): add env formatter (VAR=value output)"
```

---

## Task 3: aws-credential-process formatter

**Files:**
- Create: `internal/format/aws_credential_process.go`
- Create: `internal/format/aws_credential_process_test.go`

- [ ] **Step 1: Write the failing test**

Create `internal/format/aws_credential_process_test.go`:

```go
package format

import (
	"strings"
	"testing"
)

func TestAWSCredentialProcess_ValidJSON(t *testing.T) {
	f, ok := Get("aws-credential-process")
	if !ok {
		t.Fatal("aws-credential-process not registered")
	}
	in := `{"Version":1,"AccessKeyId":"AKIA...","SecretAccessKey":"abc","SessionToken":"tok","Expiration":"2030-01-01T00:00:00Z"}`
	out, err := f.Format(in, nil)
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != in {
		t.Fatalf("expected verbatim passthrough, got %q", string(out))
	}
}

func TestAWSCredentialProcess_MinimumKeys(t *testing.T) {
	f, _ := Get("aws-credential-process")
	in := `{"Version":1,"AccessKeyId":"AKIA","SecretAccessKey":"s"}`
	if _, err := f.Format(in, nil); err != nil {
		t.Fatalf("expected ok with minimum keys, got %v", err)
	}
}

func TestAWSCredentialProcess_NoArgsAllowed(t *testing.T) {
	f, _ := Get("aws-credential-process")
	in := `{"Version":1,"AccessKeyId":"AKIA","SecretAccessKey":"s"}`
	_, err := f.Format(in, []string{"unexpected"})
	if err == nil {
		t.Fatal("expected error when args provided")
	}
}

func TestAWSCredentialProcess_RejectsNonJSON(t *testing.T) {
	f, _ := Get("aws-credential-process")
	_, err := f.Format("not json", nil)
	if err == nil {
		t.Fatal("expected error on non-JSON input")
	}
}

func TestAWSCredentialProcess_RejectsMissingKeys(t *testing.T) {
	f, _ := Get("aws-credential-process")
	cases := []string{
		`{"AccessKeyId":"AKIA","SecretAccessKey":"s"}`,                  // missing Version
		`{"Version":1,"SecretAccessKey":"s"}`,                            // missing AccessKeyId
		`{"Version":1,"AccessKeyId":"AKIA"}`,                             // missing SecretAccessKey
		`{}`,
	}
	for _, in := range cases {
		_, err := f.Format(in, nil)
		if err == nil {
			t.Errorf("expected error for %q", in)
			continue
		}
		// Error should name what's missing or mention the expected shape.
		if !strings.Contains(err.Error(), "Version") &&
			!strings.Contains(err.Error(), "AccessKeyId") &&
			!strings.Contains(err.Error(), "SecretAccessKey") {
			t.Errorf("error for %q should name missing field, got: %v", in, err)
		}
	}
}

func TestAWSCredentialProcess_RejectsWrongVersion(t *testing.T) {
	f, _ := Get("aws-credential-process")
	in := `{"Version":2,"AccessKeyId":"AKIA","SecretAccessKey":"s"}`
	_, err := f.Format(in, nil)
	if err == nil {
		t.Fatal("expected error on Version != 1")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/format/... -run TestAWSCredentialProcess -v`
Expected: FAIL — formatter not registered.

- [ ] **Step 3: Write minimal implementation**

Create `internal/format/aws_credential_process.go`:

```go
package format

import (
	"encoding/json"
	"fmt"
)

type awsCredentialProcess struct{}

// Format validates the value as AWS credential_process JSON and returns it
// verbatim. The wire format is defined by AWS; we do not reshape it.
//
// Required keys: Version (must be 1), AccessKeyId, SecretAccessKey.
// SessionToken and Expiration are optional and pass through.
func (awsCredentialProcess) Format(value string, args []string) ([]byte, error) {
	if len(args) != 0 {
		return nil, fmt.Errorf("aws-credential-process formatter takes no arguments (got %d)", len(args))
	}
	var probe struct {
		Version         *int    `json:"Version"`
		AccessKeyId     *string `json:"AccessKeyId"`
		SecretAccessKey *string `json:"SecretAccessKey"`
	}
	if err := json.Unmarshal([]byte(value), &probe); err != nil {
		return nil, fmt.Errorf("aws-credential-process: secret value is not valid JSON: %w", err)
	}
	if probe.Version == nil {
		return nil, fmt.Errorf(`aws-credential-process: missing required key "Version"`)
	}
	if *probe.Version != 1 {
		return nil, fmt.Errorf("aws-credential-process: Version must be 1, got %d", *probe.Version)
	}
	if probe.AccessKeyId == nil {
		return nil, fmt.Errorf(`aws-credential-process: missing required key "AccessKeyId"`)
	}
	if probe.SecretAccessKey == nil {
		return nil, fmt.Errorf(`aws-credential-process: missing required key "SecretAccessKey"`)
	}
	return []byte(value), nil
}

func init() {
	Register("aws-credential-process", awsCredentialProcess{})
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/format/... -v`
Expected: PASS — all formatter tests.

- [ ] **Step 5: Commit**

```bash
git add internal/format/aws_credential_process.go internal/format/aws_credential_process_test.go
git commit -m "feat(tsm): add aws-credential-process formatter"
```

---

## Task 4: pgpass formatter

**Files:**
- Create: `internal/format/pgpass.go`
- Create: `internal/format/pgpass_test.go`

- [ ] **Step 1: Write the failing test**

Create `internal/format/pgpass_test.go`:

```go
package format

import "testing"

func TestPgpass_Valid(t *testing.T) {
	f, ok := Get("pgpass")
	if !ok {
		t.Fatal("pgpass not registered")
	}
	in := "db.example.com:5432:mydb:dbuser:s3cret"
	out, err := f.Format(in, nil)
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != in {
		t.Fatalf("expected verbatim passthrough, got %q", string(out))
	}
}

func TestPgpass_NoArgsAllowed(t *testing.T) {
	f, _ := Get("pgpass")
	_, err := f.Format("h:5432:db:user:pw", []string{"unexpected"})
	if err == nil {
		t.Fatal("expected error when args provided")
	}
}

func TestPgpass_RejectsNewline(t *testing.T) {
	f, _ := Get("pgpass")
	_, err := f.Format("host:5432:db:user:pw\nextra", nil)
	if err == nil {
		t.Fatal("expected error on embedded newline")
	}
}

func TestPgpass_RejectsTrailingNewline(t *testing.T) {
	f, _ := Get("pgpass")
	_, err := f.Format("host:5432:db:user:pw\n", nil)
	if err == nil {
		t.Fatal("expected error on trailing newline (must be exact line)")
	}
}

func TestPgpass_RejectsWrongFieldCount(t *testing.T) {
	f, _ := Get("pgpass")
	cases := []string{
		"only:four:fields:here",
		"too:many:fields:here:plus:one",
		"",
		"nofields",
	}
	for _, in := range cases {
		if _, err := f.Format(in, nil); err == nil {
			t.Errorf("expected error for %q", in)
		}
	}
}

func TestPgpass_AllowsWildcards(t *testing.T) {
	// pgpass allows * in host/port/db/user fields.
	f, _ := Get("pgpass")
	in := "*:*:*:*:s3cret"
	if _, err := f.Format(in, nil); err != nil {
		t.Fatalf("wildcards should be allowed, got %v", err)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/format/... -run TestPgpass -v`
Expected: FAIL — formatter not registered.

- [ ] **Step 3: Write minimal implementation**

Create `internal/format/pgpass.go`:

```go
package format

import (
	"fmt"
	"strings"
)

type pgpassFormatter struct{}

// Format validates the value as a single pgpass line
// (host:port:database:username:password) and returns it verbatim.
// See https://www.postgresql.org/docs/current/libpq-pgpass.html
func (pgpassFormatter) Format(value string, args []string) ([]byte, error) {
	if len(args) != 0 {
		return nil, fmt.Errorf("pgpass formatter takes no arguments (got %d)", len(args))
	}
	if strings.ContainsRune(value, '\n') {
		return nil, fmt.Errorf("pgpass: value contains a newline; pgpass entries must be a single line")
	}
	if n := strings.Count(value, ":"); n != 4 {
		return nil, fmt.Errorf("pgpass: expected 5 colon-delimited fields (host:port:db:user:password), got %d colons", n)
	}
	return []byte(value), nil
}

func init() {
	Register("pgpass", pgpassFormatter{})
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/format/... -v`
Expected: PASS — all formatter tests.

- [ ] **Step 5: Commit**

```bash
git add internal/format/pgpass.go internal/format/pgpass_test.go
git commit -m "feat(tsm): add pgpass formatter"
```

---

## Task 5: Wire `--format` into `tsm get`

**Files:**
- Modify: `cmd/get.go`
- Create: `cmd/get_test.go`

- [ ] **Step 1: Write the failing test**

Create `cmd/get_test.go`:

```go
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

func TestGet_FormatMutexWithRaw(t *testing.T) {
	mock := &mockCaller{}
	err := runGetWith(mock, "n", getOptions{
		Format:    "env FOO",
		Raw:       true,
		Stdout:    &bytes.Buffer{},
		StdoutTTY: false,
	})
	if err == nil {
		t.Fatal("expected mutex error")
	}
	if !strings.Contains(err.Error(), "--raw") {
		t.Fatalf("error should mention --raw, got: %v", err)
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./cmd/... -run TestGet -v`
Expected: FAIL — `runGetWith`, `getOptions` undefined.

- [ ] **Step 3: Refactor `cmd/get.go` to expose a testable seam and add `--format`**

Replace the contents of `cmd/get.go` with:

```go
package cmd

import (
	"fmt"
	"io"
	"os"
	"strings"

	"tsm/internal/client"
	"tsm/internal/format"

	"github.com/spf13/cobra"
	"golang.org/x/term"
)

// getOptions captures the inputs for runGetWith. Extracted for testability:
// production wires these from cobra flags + os.Stdout; tests inject directly.
type getOptions struct {
	Raw       bool
	ToFile    string
	Format    string // formatter name + optional inline args, space-separated
	Stdout    io.Writer
	StdoutTTY bool
}

func newGetCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "get <name>",
		Short: "Retrieve a secret value",
		Long: `Retrieve a secret by name.

Default:    JSON to stdout    {"name": "...", "value": "..."}
--raw:      Raw value only    (refuses if stdout is a TTY)
--to-file:  Write to file     (mode 0600, raw value, no newline)
--format F: Run value through formatter F (refuses if stdout is a TTY)
            Built-ins: env VAR, aws-credential-process, pgpass`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			raw, _ := cmd.Flags().GetBool("raw")
			toFile, _ := cmd.Flags().GetString("to-file")
			fmtSpec, _ := cmd.Flags().GetString("format")
			return withUnlockedClient(func(c client.Caller) error {
				return runGetWith(c, args[0], getOptions{
					Raw:       raw,
					ToFile:    toFile,
					Format:    fmtSpec,
					Stdout:    os.Stdout,
					StdoutTTY: term.IsTerminal(int(os.Stdout.Fd())),
				})
			})
		},
	}
	cmd.Flags().Bool("raw", false, "output raw secret value (no JSON, no newline)")
	cmd.Flags().String("to-file", "", "write secret value to file (mode 0600)")
	cmd.Flags().String("format", "", "run value through a formatter (e.g., 'env GITHUB_TOKEN', 'aws-credential-process', 'pgpass')")
	return cmd
}

func runGetWith(c client.Caller, name string, opts getOptions) error {
	// Mutex check: --format is exclusive with --raw, --to-file, and --json.
	if opts.Format != "" {
		if opts.Raw {
			return fmt.Errorf("--format cannot be combined with --raw")
		}
		if opts.ToFile != "" {
			return fmt.Errorf("--format cannot be combined with --to-file")
		}
		if jsonOutput() {
			return fmt.Errorf("--format cannot be combined with --json")
		}
	}

	var secret struct {
		Name  string `json:"name"`
		Value string `json:"value"`
	}
	if err := c.Call("vault.get", map[string]any{"name": name, "client_id": clientID()}, &secret); err != nil {
		return handleError(err)
	}

	if opts.ToFile != "" {
		if err := os.WriteFile(opts.ToFile, []byte(secret.Value), 0o600); err != nil {
			return fmt.Errorf("write to file: %w", err)
		}
		if !jsonOutput() {
			fmt.Printf("Secret written to %s\n", opts.ToFile)
		}
		return nil
	}

	if opts.Format != "" {
		if opts.StdoutTTY {
			return fmt.Errorf("refusing to write secret to terminal in --format mode\nPipe to a file or redirect: tsm get %s --format %q > out", name, opts.Format)
		}
		fmtName, args := splitFormatSpec(opts.Format)
		f, ok := format.Get(fmtName)
		if !ok {
			return fmt.Errorf("unknown formatter %q (built-ins: env, aws-credential-process, pgpass)", fmtName)
		}
		out, err := f.Format(secret.Value, args)
		if err != nil {
			return err
		}
		_, err = opts.Stdout.Write(out)
		return err
	}

	if opts.Raw {
		if opts.StdoutTTY {
			return fmt.Errorf("refusing to write secret to terminal in --raw mode\nPipe to a command or redirect: tsm get %s --raw | some-tool", name)
		}
		fmt.Fprint(opts.Stdout, secret.Value)
		return nil
	}

	return printJSON(secret)
}

// splitFormatSpec splits "env GITHUB_TOKEN" into ("env", ["GITHUB_TOKEN"]).
// A spec with no whitespace returns (name, nil).
func splitFormatSpec(spec string) (string, []string) {
	parts := strings.Fields(spec)
	if len(parts) == 0 {
		return "", nil
	}
	return parts[0], parts[1:]
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./cmd/... -run TestGet -v`
Expected: PASS — all `TestGet_*` and `TestMockCaller_*`.

Then run the full suite to confirm nothing else regressed:

Run: `go test ./...`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add cmd/get.go cmd/get_test.go
git commit -m "feat(tsm): add --format flag to tsm get with built-in formatters"
```

---

## Task 6: `runspec` parser for `--env VAR=secret`

**Files:**
- Create: `internal/runspec/runspec.go`
- Create: `internal/runspec/runspec_test.go`

- [ ] **Step 1: Write the failing test**

Create `internal/runspec/runspec_test.go`:

```go
package runspec

import (
	"strings"
	"testing"
)

func TestParse_Single(t *testing.T) {
	got, err := Parse([]string{"GITHUB_TOKEN=gh-pat"})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Fatalf("got %d mappings", len(got))
	}
	if got[0].Var != "GITHUB_TOKEN" || got[0].Secret != "gh-pat" {
		t.Fatalf("got %+v", got[0])
	}
}

func TestParse_Multiple(t *testing.T) {
	got, err := Parse([]string{
		"GITHUB_TOKEN=gh-pat",
		"LINEAR_KEY=linear-token",
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("got %d mappings", len(got))
	}
}

func TestParse_DuplicateVar(t *testing.T) {
	_, err := Parse([]string{
		"GITHUB_TOKEN=gh-pat",
		"GITHUB_TOKEN=other-pat",
	})
	if err == nil {
		t.Fatal("expected error for duplicate VAR")
	}
	if !strings.Contains(err.Error(), "GITHUB_TOKEN") {
		t.Fatalf("error should name the duplicate, got: %v", err)
	}
}

func TestParse_SameSecretMultipleVars(t *testing.T) {
	got, err := Parse([]string{
		"GITHUB_TOKEN=gh-pat",
		"GH_TOKEN=gh-pat",
	})
	if err != nil {
		t.Fatalf("same secret under multiple vars should be allowed, got: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("got %d mappings", len(got))
	}
}

func TestParse_MissingEquals(t *testing.T) {
	_, err := Parse([]string{"NO_EQUALS"})
	if err == nil {
		t.Fatal("expected error")
	}
}

func TestParse_EmptyVarOrSecret(t *testing.T) {
	cases := []string{"=value", "VAR=", "="}
	for _, in := range cases {
		if _, err := Parse([]string{in}); err == nil {
			t.Errorf("expected error for %q", in)
		}
	}
}

func TestParse_BadVarName(t *testing.T) {
	cases := []string{
		"lowercase=x",
		"1STARTS_DIGIT=x",
		"HAS-DASH=x",
		"HAS SPACE=x",
		"HAS.DOT=x",
	}
	for _, in := range cases {
		if _, err := Parse([]string{in}); err == nil {
			t.Errorf("expected error for %q", in)
		}
	}
}

func TestParse_BadSecretName(t *testing.T) {
	// Secret names follow the existing kebab-case rule:
	// ^[a-zA-Z0-9_-]{1,128}$
	cases := []string{
		"VAR=has space",
		"VAR=has/slash",
		"VAR=has.dot",
		"VAR=" + strings.Repeat("a", 129),
	}
	for _, in := range cases {
		if _, err := Parse([]string{in}); err == nil {
			t.Errorf("expected error for %q", in)
		}
	}
}

func TestParse_AcceptsValidSecretChars(t *testing.T) {
	good := []string{
		"VAR=simple",
		"VAR=with-dash",
		"VAR=with_under",
		"VAR=Mixed_Case-9",
		"VAR=" + strings.Repeat("a", 128),
	}
	for _, in := range good {
		if _, err := Parse([]string{in}); err != nil {
			t.Errorf("expected ok for %q, got %v", in, err)
		}
	}
}

func TestParse_Empty(t *testing.T) {
	got, err := Parse(nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Fatalf("expected empty, got %d", len(got))
	}
}

func TestUniqueSecrets(t *testing.T) {
	mappings := []Mapping{
		{Var: "A", Secret: "x"},
		{Var: "B", Secret: "y"},
		{Var: "C", Secret: "x"},
	}
	got := UniqueSecrets(mappings)
	if len(got) != 2 {
		t.Fatalf("expected 2 unique, got %d", len(got))
	}
	have := map[string]bool{}
	for _, s := range got {
		have[s] = true
	}
	if !have["x"] || !have["y"] {
		t.Fatalf("expected x and y, got %v", got)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/runspec/... -v`
Expected: FAIL — package does not exist.

- [ ] **Step 3: Write the implementation**

Create `internal/runspec/runspec.go`:

```go
// Package runspec parses --env VAR=secret-name flag values for tsm run into
// validated mappings. The parser does not talk to the daemon — it only
// validates the syntactic shape and the character set of the names.
package runspec

import (
	"fmt"
	"regexp"
	"strings"
)

// Mapping is one --env flag value: an env var name paired with the tsm
// secret name to source its value from.
type Mapping struct {
	Var    string
	Secret string
}

var (
	envVarRE     = regexp.MustCompile(`^[A-Z_][A-Z0-9_]*$`)
	secretNameRE = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,128}$`)
)

// Parse consumes "VAR=secret-name" strings (in --env flag order) and
// returns the resulting mappings. Returns an error if any string is
// malformed or if a VAR appears more than once.
func Parse(specs []string) ([]Mapping, error) {
	out := make([]Mapping, 0, len(specs))
	seen := map[string]int{} // VAR -> 1-based index where first seen
	for i, s := range specs {
		idx := strings.IndexByte(s, '=')
		if idx < 0 {
			return nil, fmt.Errorf("--env[%d] %q: missing '=' separator (expected VAR=secret-name)", i, s)
		}
		v := s[:idx]
		name := s[idx+1:]
		if v == "" {
			return nil, fmt.Errorf("--env[%d] %q: VAR side is empty", i, s)
		}
		if name == "" {
			return nil, fmt.Errorf("--env[%d] %q: secret name side is empty", i, s)
		}
		if !envVarRE.MatchString(v) {
			return nil, fmt.Errorf("--env[%d] %q: invalid VAR %q (must match [A-Z_][A-Z0-9_]*)", i, s, v)
		}
		if !secretNameRE.MatchString(name) {
			return nil, fmt.Errorf("--env[%d] %q: invalid secret name %q (must match [a-zA-Z0-9_-]{1,128})", i, s, name)
		}
		if prev, ok := seen[v]; ok {
			return nil, fmt.Errorf("--env[%d] %q: VAR %q already specified at --env[%d]", i, s, v, prev-1)
		}
		seen[v] = i + 1
		out = append(out, Mapping{Var: v, Secret: name})
	}
	return out, nil
}

// UniqueSecrets returns the set of distinct secret names referenced by
// mappings, in first-seen order. Useful for de-duplicating vault.get calls
// when the same secret is bound to multiple env vars.
func UniqueSecrets(mappings []Mapping) []string {
	seen := map[string]bool{}
	out := make([]string, 0, len(mappings))
	for _, m := range mappings {
		if seen[m.Secret] {
			continue
		}
		seen[m.Secret] = true
		out = append(out, m.Secret)
	}
	return out
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/runspec/... -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/runspec/runspec.go internal/runspec/runspec_test.go
git commit -m "feat(tsm): add internal/runspec parser for --env VAR=secret mappings"
```

---

## Task 7: `tsm run` skeleton (cobra subcommand, parses flags, no exec yet)

**Files:**
- Create: `cmd/run.go`
- Create: `cmd/run_test.go`
- Modify: `cmd/root.go` (register newRunCmd)
- Modify: `cmd/root_test.go` (add "run" to expected list)

- [ ] **Step 1: Write the failing test**

Create `cmd/run_test.go`:

```go
package cmd

import (
	"errors"
	"strings"
	"testing"

	"tsm/internal/jsonrpc"
)

// recordedExec captures what runWith would have execve'd.
type recordedExec struct {
	Path string
	Argv []string
	Env  []string // only the env vars added by tsm run, not the full inherited env
}

// fakeRunner is the test double for the production execve runner.
func newFakeRunner(into *recordedExec) runnerFunc {
	return func(path string, argv, addedEnv []string) error {
		into.Path = path
		into.Argv = argv
		into.Env = addedEnv
		return nil // simulating successful exec (no return in production)
	}
}

func TestRun_BadEnvFlag(t *testing.T) {
	mock := &mockCaller{}
	var rec recordedExec
	err := runWith(mock, runOptions{
		Envs:    []string{"NO_EQUALS"},
		Argv:    []string{"echo"},
		StdinTTY: true,
		Runner:  newFakeRunner(&rec),
	})
	if err == nil {
		t.Fatal("expected parse error")
	}
	if !strings.Contains(err.Error(), "missing '='") {
		t.Fatalf("expected missing '=' error, got: %v", err)
	}
	if rec.Path != "" {
		t.Fatal("runner must not be called when parse fails")
	}
}

func TestRun_NoCommand(t *testing.T) {
	mock := &mockCaller{}
	var rec recordedExec
	err := runWith(mock, runOptions{
		Envs:    []string{"FOO=bar"},
		Argv:    nil,
		StdinTTY: true,
		Runner:  newFakeRunner(&rec),
	})
	if err == nil {
		t.Fatal("expected error when no command provided")
	}
}

func TestRun_Success(t *testing.T) {
	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			switch method {
			case "vault.unlock":
				return nil, nil
			case "vault.list":
				return []map[string]any{
					{"name": "gh-pat", "confirm": false},
				}, nil
			case "vault.get":
				if params["name"] == "gh-pat" {
					return map[string]string{"name": "gh-pat", "value": "ghp_abc"}, nil
				}
				return nil, errors.New("unexpected secret " + params["name"].(string))
			}
			return nil, errors.New("unexpected method " + method)
		},
	}
	var rec recordedExec
	err := runWith(mock, runOptions{
		Envs:     []string{"GITHUB_TOKEN=gh-pat"},
		Argv:     []string{"echo", "hi"},
		StdinTTY: true,
		Runner:   newFakeRunner(&rec),
		LookPath: func(name string) (string, error) { return "/bin/" + name, nil },
	})
	if err != nil {
		t.Fatal(err)
	}
	if rec.Path != "/bin/echo" {
		t.Fatalf("expected /bin/echo, got %q", rec.Path)
	}
	if len(rec.Argv) != 2 || rec.Argv[0] != "echo" || rec.Argv[1] != "hi" {
		t.Fatalf("argv: %v", rec.Argv)
	}
	if len(rec.Env) != 1 || rec.Env[0] != "GITHUB_TOKEN=ghp_abc" {
		t.Fatalf("env: %v", rec.Env)
	}
}

func TestRun_SecretNotFound(t *testing.T) {
	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			switch method {
			case "vault.unlock":
				return nil, nil
			case "vault.list":
				return []map[string]any{}, nil
			case "vault.get":
				return nil, &jsonrpc.RPCError{Code: jsonrpc.CodeSecretNotFound, Message: "not found"}
			}
			return nil, errors.New("unexpected")
		},
	}
	var rec recordedExec
	err := runWith(mock, runOptions{
		Envs:     []string{"GITHUB_TOKEN=missing"},
		Argv:     []string{"echo"},
		StdinTTY: true,
		Runner:   newFakeRunner(&rec),
		LookPath: func(name string) (string, error) { return "/bin/" + name, nil },
	})
	if err == nil {
		t.Fatal("expected error")
	}
	if rec.Path != "" {
		t.Fatal("runner must not be invoked when a secret resolution fails")
	}
}

func TestRun_TargetNotFound(t *testing.T) {
	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			switch method {
			case "vault.unlock":
				return nil, nil
			case "vault.list":
				return []map[string]any{{"name": "x", "confirm": false}}, nil
			case "vault.get":
				return map[string]string{"name": "x", "value": "v"}, nil
			}
			return nil, errors.New("unexpected")
		},
	}
	var rec recordedExec
	err := runWith(mock, runOptions{
		Envs:     []string{"FOO=x"},
		Argv:     []string{"nonexistent-binary-xyz"},
		StdinTTY: true,
		Runner:   newFakeRunner(&rec),
		LookPath: func(name string) (string, error) { return "", errors.New("not found in PATH") },
	})
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "not found") {
		t.Fatalf("error should mention not found, got: %v", err)
	}
}

func TestRun_ConfirmAndNonTTY_Refused(t *testing.T) {
	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			switch method {
			case "vault.unlock":
				return nil, nil
			case "vault.list":
				return []map[string]any{{"name": "billing-key", "confirm": true}}, nil
			}
			return nil, errors.New("unexpected " + method)
		},
	}
	var rec recordedExec
	err := runWith(mock, runOptions{
		Envs:     []string{"BILLING=billing-key"},
		Argv:     []string{"echo"},
		StdinTTY: false, // not a TTY
		Runner:   newFakeRunner(&rec),
		LookPath: func(name string) (string, error) { return "/bin/" + name, nil },
	})
	if err == nil {
		t.Fatal("expected refusal")
	}
	if !strings.Contains(err.Error(), "billing-key") {
		t.Fatalf("error should name the offending secret, got: %v", err)
	}
	if !strings.Contains(err.Error(), "TTY") && !strings.Contains(err.Error(), "tty") {
		t.Fatalf("error should mention TTY, got: %v", err)
	}
	if rec.Path != "" {
		t.Fatal("runner must not be invoked")
	}
}

func TestRun_DedupesVaultGets(t *testing.T) {
	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			switch method {
			case "vault.unlock":
				return nil, nil
			case "vault.list":
				return []map[string]any{{"name": "gh-pat", "confirm": false}}, nil
			case "vault.get":
				return map[string]string{"name": "gh-pat", "value": "ghp_abc"}, nil
			}
			return nil, errors.New("unexpected")
		},
	}
	var rec recordedExec
	err := runWith(mock, runOptions{
		Envs:     []string{"GITHUB_TOKEN=gh-pat", "GH_TOKEN=gh-pat"},
		Argv:     []string{"echo"},
		StdinTTY: true,
		Runner:   newFakeRunner(&rec),
		LookPath: func(name string) (string, error) { return "/bin/" + name, nil },
	})
	if err != nil {
		t.Fatal(err)
	}
	getCount := 0
	for _, c := range mock.calls {
		if c.Method == "vault.get" {
			getCount++
		}
	}
	if getCount != 1 {
		t.Fatalf("expected 1 vault.get (deduped), got %d", getCount)
	}
	// Both env vars should be present in the recorded env.
	if len(rec.Env) != 2 {
		t.Fatalf("expected 2 env vars, got %v", rec.Env)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./cmd/... -run TestRun -v`
Expected: FAIL — `runWith`, `runOptions`, `runnerFunc`, `newRunCmd` undefined.

- [ ] **Step 3: Write the implementation**

Create `cmd/run.go`:

```go
package cmd

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path"
	"strings"

	"tsm/internal/client"
	"tsm/internal/jsonrpc"
	"tsm/internal/runspec"

	"github.com/spf13/cobra"
	"golang.org/x/sys/unix"
	"golang.org/x/term"
)

// runnerFunc replaces the current process with the given target. In
// production, this is execveRunner (which uses unix.Exec and never returns
// on success). In tests, a fake records the would-be invocation.
//
// addedEnv contains only the VAR=value pairs that tsm run added; the full
// environment (current env + added) is what the production runner passes to
// the child via execve.
type runnerFunc func(path string, argv, addedEnv []string) error

// runOptions captures all inputs for runWith. Extracted for testability.
type runOptions struct {
	Envs     []string         // raw --env flag values, in order
	Argv     []string         // target command + args
	StdinTTY bool             // result of term.IsTerminal(os.Stdin.Fd())
	Runner   runnerFunc       // exec replacement
	LookPath func(string) (string, error)
}

// secretMeta is the minimum we need from vault.list to know if a secret is
// confirm-gated before we try to use it.
type runSecretMeta struct {
	Name    string `json:"name"`
	Confirm bool   `json:"confirm"`
}

func newRunCmd() *cobra.Command {
	var envs []string
	cmd := &cobra.Command{
		Use:   "run --env VAR=secret [--env ...] -- <command> [args...]",
		Short: "Run a command with secrets injected as environment variables",
		Long: `Run a target command with one or more secrets bound to environment
variables for the duration of that subprocess.

The mapping is caller-side: --env VAR=secret-name binds the value of the
named tsm secret to environment variable VAR in the child process. The
parent shell is unaffected; the env var is gone when the child exits.

Use this for tools that read credentials from environment variables
(gh GITHUB_TOKEN, AWS_ACCESS_KEY_ID, MCP servers in .mcp.json, etc.).
For tools that read from files, use 'tsm get --to-file' or process
substitution: <(tsm get NAME --raw).

Examples:
  tsm run --env GITHUB_TOKEN=gh-pat -- gh pr list
  tsm run --env A=key-a --env B=key-b -- ./deploy.sh prod`,
		DisableFlagsInUseLine: true,
		Args:                  cobra.MinimumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return withClient(func(c client.Caller) error {
				return runWith(c, runOptions{
					Envs:     envs,
					Argv:     args,
					StdinTTY: term.IsTerminal(int(os.Stdin.Fd())),
					Runner:   execveRunner,
					LookPath: exec.LookPath,
				})
			})
		},
	}
	cmd.Flags().StringArrayVar(&envs, "env", nil, "bind a secret to an env var (VAR=secret-name); repeatable")
	return cmd
}

func runWith(c client.Caller, opts runOptions) error {
	if len(opts.Argv) == 0 {
		return errors.New("missing target command (usage: tsm run --env VAR=secret -- <command> [args...])")
	}

	mappings, err := runspec.Parse(opts.Envs)
	if err != nil {
		return err
	}

	// Unlock vault (Touch ID once, upfront) before any vault.get.
	if err := c.Call("vault.unlock", nil, nil); err != nil {
		return handleError(err)
	}

	// Inspect confirm flags via vault.list before fetching, so we can refuse
	// non-TTY callers without first triggering a Touch ID prompt that they
	// could not respond to.
	if !opts.StdinTTY {
		var metas []runSecretMeta
		if err := c.Call("vault.list", nil, &metas); err != nil {
			return handleError(err)
		}
		needed := map[string]bool{}
		for _, m := range mappings {
			needed[m.Secret] = true
		}
		var blocking []string
		for _, m := range metas {
			if needed[m.Name] && m.Confirm {
				blocking = append(blocking, m.Name)
			}
		}
		if len(blocking) > 0 {
			return fmt.Errorf("refusing to run: secret(s) require confirm-mode authentication but stdin is not a TTY: %s\nChange the secret's confirm setting via 'tsm edit' if non-interactive use is intended", strings.Join(blocking, ", "))
		}
	}

	// Resolve target before triggering Touch ID for vault.get — fail fast on
	// PATH errors so the user doesn't authenticate just to hit "not found".
	targetPath, err := opts.LookPath(opts.Argv[0])
	if err != nil {
		return fmt.Errorf("command %q not found in PATH", opts.Argv[0])
	}

	// Resolve secrets, deduplicated by secret name.
	values := map[string]string{} // secret name -> value
	for _, name := range runspec.UniqueSecrets(mappings) {
		var s struct {
			Name  string `json:"name"`
			Value string `json:"value"`
		}
		params := map[string]any{
			"name":      name,
			"client_id": runClientID(path.Base(targetPath)),
		}
		if err := c.Call("vault.get", params, &s); err != nil {
			if rpcErr, ok := err.(*jsonrpc.RPCError); ok {
				return errors.New(formatRPCError(rpcErr))
			}
			return err
		}
		values[name] = s.Value
	}

	// Build the added-env slice in mapping order.
	addedEnv := make([]string, 0, len(mappings))
	for _, m := range mappings {
		addedEnv = append(addedEnv, m.Var+"="+values[m.Secret])
	}

	return opts.Runner(targetPath, opts.Argv, addedEnv)
}

// execveRunner is the production runnerFunc. It calls unix.Exec, which
// replaces the current process; on success it does not return.
func execveRunner(path string, argv, addedEnv []string) error {
	full := append(os.Environ(), addedEnv...)
	return unix.Exec(path, argv, full)
}

// runClientID returns the client_id used in vault.get audit log entries
// for tsm run invocations.
func runClientID(targetBasename string) string {
	return fmt.Sprintf("tsm-run/pid:%d/%s", os.Getpid(), targetBasename)
}
```

- [ ] **Step 4: Register the command in `cmd/root.go`**

Modify `cmd/root.go` — add `newRunCmd()` to the `AddCommand` list:

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
		newRunCmd(),
	)
```

- [ ] **Step 5: Update `cmd/root_test.go`**

Modify the expected list in `TestRootCmd_HasAllSubcommands`:

```go
	expected := []string{
		"version", "status", "lock", "unlock",
		"ensure-daemon", "list", "init", "add",
		"get", "edit", "remove", "reset",
		"config", "log", "run",
	}
```

- [ ] **Step 6: Run tests**

Run: `go test ./...`
Expected: PASS — including all `TestRun_*`, `TestGet_*`, formatter tests, runspec tests, root subcommand check.

- [ ] **Step 7: Commit**

```bash
git add cmd/run.go cmd/run_test.go cmd/root.go cmd/root_test.go
git commit -m "feat(tsm): add tsm run for env-var-injected subprocess execution"
```

---

## Task 8: Update CLAUDE.md note about plugin/skill maintenance

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Read the current CLAUDE.md to find the right place**

Run: `grep -n "Plan 3\|MCP\|## Conventions" CLAUDE.md`

- [ ] **Step 2: Edit CLAUDE.md**

Find the "## Conventions" section and add a new bullet at the end:

```markdown
- **Plugin skill stays in sync with the CLI.** PRs that change `tsm` flags, command names, or output shapes must update `plugin/skills/credential-usage/SKILL.md` in the same commit. The skill is what the agent reads to figure out how to use tsm; stale skill text is worse than no skill.
```

Then update the "Plans (read before making non-trivial changes)" list — replace the line about Plan 3 not yet being written:

Old:
```
Plan 3 (MCP server, `tsm schema`, Claude Code plugin) is not yet written. When it's authored, the MCP `vault_list` tool schema must include `display_name`, and `vault_get` documentation must specify that the **id** is the lookup key (not the display name).
```

New:
```
- `docs/plans/2026-04-25-tsm-agent-integration-design.md` — Plan 3 design (agent integration via `tsm run`, `tsm get --format`, and the Claude Code plugin). Drops the previously-planned `tsm mcp` and `tsm schema` in favor of the existing CLI surface.
- `docs/plans/2026-04-25-tsm-agent-integration-impl.md` — Plan 3 implementation tasks.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: note plugin skill must stay in sync with CLI surface"
```

---

## Task 9: Plugin manifest, hook, and permission allowlist

**Files:**
- Create: `plugin/.claude-plugin/plugin.json`
- Create: `plugin/hooks/hooks.json`
- Create: `plugin/settings.json`

- [ ] **Step 1: Create the manifest**

Create `plugin/.claude-plugin/plugin.json`:

```json
{
  "name": "tsm",
  "version": "0.1.0",
  "description": "Touch-ID-gated secrets for AI coding agents. Provides safe credential injection for tools and MCP servers.",
  "author": "Carl Tashian"
}
```

- [ ] **Step 2: Create the SessionStart hook**

Create `plugin/hooks/hooks.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          {
            "type": "command",
            "command": "tsm ensure-daemon"
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 3: Create the permission allowlist**

Create `plugin/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(tsm list)",
      "Bash(tsm list:*)",
      "Bash(tsm status)",
      "Bash(tsm status:*)",
      "Bash(tsm get:*)",
      "Bash(tsm run:*)",
      "Bash(tsm log)",
      "Bash(tsm log:*)",
      "Bash(tsm ensure-daemon)",
      "Bash(tsm lock)",
      "Bash(tsm unlock)"
    ]
  }
}
```

- [ ] **Step 4: Validate JSON files parse**

Run: `for f in plugin/.claude-plugin/plugin.json plugin/hooks/hooks.json plugin/settings.json; do python3 -m json.tool "$f" > /dev/null && echo "$f OK"; done`
Expected: Three "OK" lines.

- [ ] **Step 5: Commit**

```bash
git add plugin/.claude-plugin/plugin.json plugin/hooks/hooks.json plugin/settings.json
git commit -m "feat(plugin): add Claude Code plugin manifest, hook, and allowlist"
```

---

## Task 10: Plugin skill — `credential-usage`

**Files:**
- Create: `plugin/skills/credential-usage/SKILL.md`
- Create: `plugin/README.md`

- [ ] **Step 1: Create the skill**

Create `plugin/skills/credential-usage/SKILL.md`:

````markdown
---
name: credential-usage
description: Use whenever a task requires an API key, token, password, or other credential. Checks the local tsm vault first; teaches safe retrieval patterns by tool category.
---

# Using credentials from the tsm vault

When a task needs an API key, token, password, database URL, or other credential, use the local `tsm` vault before asking the user for it. The vault is biometric-gated (Touch ID) and the user has already approved the patterns below by installing this plugin.

## 1. Discover first

Run `tsm list --json` before assuming a credential is missing. Look for a name, description, or tag that matches what you need.

```bash
tsm list --json
# [{"name":"gh-pat","display_name":"GitHub PAT","description":"...","confirm":false,"tags":["github","git"]}, ...]
```

If `tsm list` shows the credential, use it via one of the patterns below. Only ask the user if no matching secret exists.

## 2. Pattern by tool category

Pick the pattern that matches the consuming tool. Never fall back to a less safe pattern just because it is shorter.

### MCP server credentials

MCP server configs in `.mcp.json` accept `command`/`args`. Wrap the server in `tsm run`:

```json
{
  "github": {
    "command": "tsm",
    "args": ["run", "--env", "GITHUB_TOKEN=gh-pat", "--", "github-mcp-server"]
  }
}
```

### Env-var CLI tools (gh, openai, anthropic, aws, etc.)

For one-off invocations:

```bash
tsm run --env GITHUB_TOKEN=gh-pat -- gh pr list
tsm run --env OPENAI_API_KEY=openai-key -- openai api models.list
```

For one-shot value capture inside a single shell pipeline (no env-var leakage):

```bash
curl -H "Authorization: Bearer $(tsm get gh-pat --raw)" https://api.github.com/user
```

### File-flag tools (curl --cacert, psql --pgpass, gcloud --key-file)

Process substitution keeps the secret off disk entirely:

```bash
curl --cacert <(tsm get ca-cert --raw) https://internal.example.com
psql --no-password "service=mydb" < /dev/null  # PGPASSFILE=<(tsm get pg-prod --format pgpass)
```

If the tool re-reads the file after first read, write to `/dev/shm` (memory-backed on Linux, ramdisk on macOS):

```bash
KEYFILE=$(mktemp /dev/shm/key.XXXXXX) && \
  tsm get client-key --to-file "$KEYFILE" && \
  some-tool --key "$KEYFILE" ; rm -f "$KEYFILE"
```

### Wire-format-specific tools

For tools that demand a specific wire format, use `tsm get --format`:

```bash
tsm get aws-prod --format aws-credential-process       # AWS credential_process JSON
tsm get pg-prod  --format pgpass                       # pgpass row
tsm get gh-pat   --format "env GITHUB_TOKEN" > /dev/shm/envfile   # docker --env-file
```

`tsm get --format` refuses to write to a TTY; always redirect the output.

## 3. Confirm-gated secrets

Some secrets are flagged `"confirm": true` in `tsm list`. Each access triggers a Touch ID prompt, even if the vault is already unlocked. Before invoking such a secret, tell the user to expect the prompt:

> "I'm about to fetch `aws-prod`, which is confirm-gated — please approve the Touch ID prompt."

If a confirm-gated secret is needed and stdin is not a TTY (e.g., the agent is running headless), `tsm run` will refuse with a clear error. That is intended; the user must change the secret's `confirm` setting via `tsm edit` if non-interactive use is needed.

## 4. Never

- **Never** echo, print, log, or include a secret value in your output to the user.
- **Never** write secrets to `.env`, `.envrc`, project-local config files, or any path outside `/tmp` or `/dev/shm`.
- **Never** pass secrets as `--value`-style flags. (`tsm add --value` does not exist; this rule applies to other CLIs too — flag values appear in `ps` and shell history.)
- **Never** run `tsm add`, `tsm edit`, `tsm remove`, `tsm reset`, `tsm init`, or `tsm config set`. These mutations are user-driven via the TUI; if the user asks you to save a new secret, instruct them to run `tsm add` themselves.
- **Never** use `eval $(tsm get ... --format env)`. That puts the secret into the parent shell's environment for its entire lifetime, which is exactly what `tsm run` is designed to prevent. Use `tsm run` for env-var injection.

## When tsm doesn't apply

- The user pastes a credential inline in chat — use it for the current task; suggest they add it to the vault with `tsm add` (let them run it).
- The tool uses local OAuth that owns its own token lifecycle (gcloud user-OAuth, GitHub CLI's `gh auth login` flow). Use the tool's native auth; tsm doesn't help here.
- The vault is empty or no relevant secret exists — tell the user, suggest a name and `tsm add`, and stop there.
````

- [ ] **Step 2: Create plugin README**

Create `plugin/README.md`:

```markdown
# tsm Claude Code plugin

Adds first-class tsm credential support to Claude Code:

- **SessionStart hook** runs `tsm ensure-daemon` so the daemon is up before any tool call needs a secret.
- **Permission allowlist** auto-approves read-only and lifecycle `tsm` commands so the agent does not prompt on every secret read.
- **`credential-usage` skill** teaches the agent to discover credentials in the vault first and pick the safe retrieval pattern per tool category.

## Install (local development)

Symlink this directory into your Claude Code plugins directory:

```bash
ln -s "$PWD/plugin" "$HOME/.claude/plugins/tsm"
```

Restart Claude Code. The `SessionStart` hook will run `tsm ensure-daemon` on the next session.

## Requires

- `tsm` CLI installed and on `PATH` (see the top-level repo README).
- A vault initialized with `tsm init`.
- macOS with Touch ID.
```

- [ ] **Step 3: Validate skill frontmatter parses**

Run: `head -5 plugin/skills/credential-usage/SKILL.md | grep -E "^(---|name:|description:)"`
Expected: lines for `---`, `name:`, `description:`, `---`.

- [ ] **Step 4: Commit**

```bash
git add plugin/skills/credential-usage/SKILL.md plugin/README.md
git commit -m "feat(plugin): add credential-usage skill and plugin README"
```

---

## Task 11: Manual smoke checklist (no commit)

This task is verification, not code. Execute each step and tick it off.

**Pre-requisites:**
- `tsm` and `tsmd` installed in `~/.local/bin` (`go build -o ~/.local/bin/tsm .` and `cp tsmd/.build/release/tsmd ~/.local/bin/tsmd`).
- A vault initialized (`tsm init`) with at least two test secrets: one ordinary (`echo "test-value-1" | tsm add --no-input --name test-plain`), and one confirm-gated (set `confirm: true` via `tsm edit test-confirm`).

- [ ] **Step 1: Verify `tsm get --format env` smoke**

```bash
tsm get test-plain --format "env TEST_PLAIN" | cat
```
Expected: `TEST_PLAIN=test-value-1` followed by a newline. Touch ID may prompt if the vault is locked.

- [ ] **Step 2: Verify TTY refusal**

```bash
tsm get test-plain --format "env TEST_PLAIN"
```
Expected: error mentioning "terminal" and a suggestion to redirect.

- [ ] **Step 3: Verify mutex flag rejection**

```bash
tsm get test-plain --format "env X" --raw 2>&1
tsm get test-plain --format "env X" --to-file /tmp/x 2>&1
tsm get test-plain --format "env X" --json 2>&1
```
Expected: each prints an error mentioning the conflicting flag and exits non-zero.

- [ ] **Step 4: Verify `tsm run` happy path**

```bash
tsm run --env TEST_PLAIN=test-plain -- printenv TEST_PLAIN
```
Expected: prints `test-value-1` and exits 0.

- [ ] **Step 5: Verify `tsm run` does not pollute parent env**

```bash
tsm run --env TEST_PLAIN=test-plain -- true
echo "TEST_PLAIN in parent: ${TEST_PLAIN:-<unset>}"
```
Expected: `TEST_PLAIN in parent: <unset>`.

- [ ] **Step 6: Verify `tsm run` confirm + non-TTY refusal**

```bash
echo "" | tsm run --env X=test-confirm -- true
```
Expected: error naming `test-confirm` and mentioning TTY; exit non-zero. The Touch ID prompt should NOT appear.

- [ ] **Step 7: Verify `tsm run` confirm + TTY succeeds**

```bash
tsm run --env X=test-confirm -- printenv X
```
Expected: Touch ID prompts; on approval, prints the secret value and exits 0.

- [ ] **Step 8: Verify `tsm run` target-not-found**

```bash
tsm run --env X=test-plain -- nonexistent-binary-xyz
```
Expected: error mentioning "not found"; no Touch ID prompt should fire because PATH resolution happens after vault.list but before vault.get for ordinary secrets — verify by running with vault locked first (`tsm lock` then re-run).

Note: with the implementation as written, vault.unlock fires before LookPath, so a locked vault will Touch-ID-prompt before the PATH error. Document this as known behavior; reorder if it matters in practice.

- [ ] **Step 9: Install plugin into a sandbox Claude Code project**

In a scratch directory:

```bash
mkdir -p ~/.claude/plugins
ln -sf "$PWD/plugin" ~/.claude/plugins/tsm
```

Open the scratch directory in Claude Code. Verify:
- New session: `tsm ensure-daemon` runs as part of SessionStart (check `tsm status` shows daemon PID).
- Ask the agent something that needs a credential ("call the GitHub API and list my PRs"). Verify it runs `tsm list --json` first without prompting permission.
- Verify `tsm run --env GITHUB_TOKEN=gh-pat -- gh ...` runs without permission prompt.
- Verify `tsm add foo` is NOT auto-approved (permission prompt appears).

- [ ] **Step 10: Verify access log captures `tsm-run` client_id**

```bash
tsm run --env X=test-plain -- true
tsm log | tail -5
```
Expected: most recent entry shows `"client_id": "tsm-run/pid:<N>/true"` for the `vault.get` call.

---

## Task 12: README update

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read the current README to see its shape**

Run: `cat README.md`

- [ ] **Step 2: Add a "For agents (Claude Code)" section**

If the README already has command/usage sections, insert a new section after them. If not, append it at the end.

```markdown
## For Claude Code

Install the bundled plugin to give Claude Code first-class tsm support:

```bash
mkdir -p ~/.claude/plugins
ln -sf "$PWD/plugin" ~/.claude/plugins/tsm
```

The plugin:
- Runs `tsm ensure-daemon` at session start.
- Auto-approves read-only `tsm` commands so the agent does not prompt on every read.
- Ships an opinionated `credential-usage` skill that teaches the agent to discover credentials in the vault before asking.

## Running tools with vault-injected env vars

```bash
tsm run --env GITHUB_TOKEN=gh-pat -- gh pr list
tsm run --env OPENAI_API_KEY=openai-key -- openai api models.list
```

The env var lives only inside the child process; the parent shell is unaffected.

## Output formatters

For tools that read credentials from a specific wire format:

```bash
tsm get aws-prod --format aws-credential-process > ~/.aws/credentials.json
tsm get pg-prod  --format pgpass                 > ~/.pgpass
tsm get gh-pat   --format "env GITHUB_TOKEN"     > /dev/shm/envfile
```
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document tsm run, --format, and the Claude Code plugin"
```

---

## Spec coverage check

| Spec section | Implementing task |
|---|---|
| `cmd/run.go` new subcommand | Task 7 |
| `cmd/get.go` `--format` flag | Task 5 |
| `internal/format/` package | Tasks 1-4 |
| `internal/runspec/` package | Task 6 |
| `plugin/.claude-plugin/plugin.json` | Task 9 |
| `plugin/hooks/hooks.json` | Task 9 |
| `plugin/settings.json` | Task 9 |
| `plugin/skills/credential-usage/SKILL.md` | Task 10 |
| `tsm run` command surface (--env, --, etc.) | Task 7 |
| `tsm run` behavior (parse → unlock → list → get → exec) | Task 7 |
| `tsm run` confirm + non-TTY refusal | Task 7 |
| `tsm run` exit codes | Task 7 (covered by RPC error formatting + cobra exit) |
| `tsm run` audit (`client_id` includes target basename) | Task 7 (`runClientID`) |
| `tsm get --format` mutex with --raw/--to-file/--json | Task 5 |
| `tsm get --format` TTY refusal | Task 5 |
| `tsm get --format` formatter dispatch | Task 5 |
| Built-in formatters (env, aws-credential-process, pgpass) | Tasks 2-4 |
| Plugin allowlist (read-only + lock + unlock) | Task 9 |
| Plugin allowlist excludes mutations | Task 9 |
| Skill structure (4 patterns + Never list) | Task 10 |
| Daemon: no changes | (n/a — explicitly out of scope) |
| Vault format: no changes | (n/a — explicitly out of scope) |
| Skill staleness mitigation (CLAUDE.md note) | Task 8 |
| Manual plugin smoke testing | Task 11 |
| README updates | Task 12 |

All sections covered. No placeholders remain. Type and method signatures are consistent across tasks (`runWith`, `runOptions`, `runnerFunc`, `runspec.Mapping`, `format.Formatter` are defined once and referenced consistently in later tasks).
