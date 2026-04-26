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
		Envs:     []string{"NO_EQUALS"},
		Argv:     []string{"echo"},
		StdinTTY: true,
		Runner:   newFakeRunner(&rec),
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
		Envs:     []string{"FOO=bar"},
		Argv:     nil,
		StdinTTY: true,
		Runner:   newFakeRunner(&rec),
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
