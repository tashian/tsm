package cmd

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

// stubGetwd returns a fixed value, simulating os.Getwd in a deterministic way.
func stubGetwd(p string) func() (string, error) {
	return func() (string, error) { return p, nil }
}

// identitySymlinks is an EvalSymlinks stub that returns the input unchanged.
// Real symlink resolution is filesystem-bound and not what these tests target.
func identitySymlinks(p string) (string, error) { return p, nil }

func TestAdd_HereSendsScopeProject(t *testing.T) {
	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			return nil, nil
		},
	}
	var stdout bytes.Buffer
	err := runAddWith(mock, addOptions{
		Name:         "foo",
		NoInput:      true,
		Here:         true,
		Stdin:        strings.NewReader("ghp_value\n"),
		Stdout:       &stdout,
		Getwd:        stubGetwd("/Users/carl/code/proj"),
		EvalSymlinks: identitySymlinks,
	})
	if err != nil {
		t.Fatal(err)
	}

	// Find the vault.add call.
	var addCall *mockCall
	for i := range mock.calls {
		if mock.calls[i].Method == "vault.add" {
			addCall = &mock.calls[i]
			break
		}
	}
	if addCall == nil {
		t.Fatal("expected vault.add call")
	}
	if got := addCall.Params["scope"]; got != "project" {
		t.Fatalf("scope: got %v, want project", got)
	}
	roots, ok := addCall.Params["roots"].([]string)
	if !ok {
		t.Fatalf("roots: expected []string, got %T (%v)", addCall.Params["roots"], addCall.Params["roots"])
	}
	if len(roots) != 1 || roots[0] != "/Users/carl/code/proj" {
		t.Fatalf("roots: got %v, want [/Users/carl/code/proj]", roots)
	}
	if !strings.Contains(stdout.String(), "scope: project") {
		t.Fatalf("stdout should mention project scope, got: %q", stdout.String())
	}
}

func TestAdd_MultipleProjectFlagsAccumulate(t *testing.T) {
	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			return nil, nil
		},
	}
	err := runAddWith(mock, addOptions{
		Name:         "foo",
		NoInput:      true,
		Projects:     []string{"/a", "/b"},
		Stdin:        strings.NewReader("v\n"),
		Stdout:       &bytes.Buffer{},
		Getwd:        stubGetwd("/whatever"),
		EvalSymlinks: identitySymlinks,
	})
	if err != nil {
		t.Fatal(err)
	}
	var addCall *mockCall
	for i := range mock.calls {
		if mock.calls[i].Method == "vault.add" {
			addCall = &mock.calls[i]
		}
	}
	if addCall == nil {
		t.Fatal("expected vault.add")
	}
	roots, _ := addCall.Params["roots"].([]string)
	if len(roots) != 2 || roots[0] != "/a" || roots[1] != "/b" {
		t.Fatalf("got roots %v, want [/a /b]", roots)
	}
}

func TestAdd_HereAndProjectCombine(t *testing.T) {
	mock := &mockCaller{onCall: func(method string, params map[string]any) (any, error) { return nil, nil }}
	err := runAddWith(mock, addOptions{
		Name:         "foo",
		NoInput:      true,
		Here:         true,
		Projects:     []string{"/extra"},
		Stdin:        strings.NewReader("v\n"),
		Stdout:       &bytes.Buffer{},
		Getwd:        stubGetwd("/here"),
		EvalSymlinks: identitySymlinks,
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range mock.calls {
		if c.Method != "vault.add" {
			continue
		}
		roots, _ := c.Params["roots"].([]string)
		if len(roots) != 2 || roots[0] != "/here" || roots[1] != "/extra" {
			t.Fatalf("got roots %v, want [/here /extra]", roots)
		}
		return
	}
	t.Fatal("expected vault.add call")
}

func TestAdd_NoScopeFlagsLeavesItGlobal(t *testing.T) {
	mock := &mockCaller{onCall: func(method string, params map[string]any) (any, error) { return nil, nil }}
	err := runAddWith(mock, addOptions{
		Name:         "foo",
		NoInput:      true,
		Stdin:        strings.NewReader("v\n"),
		Stdout:       &bytes.Buffer{},
		Getwd:        stubGetwd("/whatever"),
		EvalSymlinks: identitySymlinks,
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range mock.calls {
		if c.Method != "vault.add" {
			continue
		}
		if _, ok := c.Params["scope"]; ok {
			t.Fatalf("global add should not send scope param; params=%v", c.Params)
		}
		if _, ok := c.Params["roots"]; ok {
			t.Fatalf("global add should not send roots param; params=%v", c.Params)
		}
		return
	}
	t.Fatal("expected vault.add call")
}

func TestAdd_RejectsRelativeProjectPath(t *testing.T) {
	mock := &mockCaller{onCall: func(method string, params map[string]any) (any, error) { return nil, nil }}
	err := runAddWith(mock, addOptions{
		Name:         "foo",
		NoInput:      true,
		Projects:     []string{"relative/path"},
		Stdin:        strings.NewReader("v\n"),
		Stdout:       &bytes.Buffer{},
		Getwd:        stubGetwd("/whatever"),
		EvalSymlinks: identitySymlinks,
	})
	if err == nil {
		t.Fatal("expected error for relative path")
	}
	if !strings.Contains(err.Error(), "absolute") {
		t.Fatalf("error should mention absolute, got: %v", err)
	}
}

func TestAdd_HereGetwdErrorPropagates(t *testing.T) {
	mock := &mockCaller{onCall: func(method string, params map[string]any) (any, error) { return nil, nil }}
	err := runAddWith(mock, addOptions{
		Name:         "foo",
		NoInput:      true,
		Here:         true,
		Stdin:        strings.NewReader("v\n"),
		Stdout:       &bytes.Buffer{},
		Getwd:        func() (string, error) { return "", errors.New("boom") },
		EvalSymlinks: identitySymlinks,
	})
	if err == nil {
		t.Fatal("expected error when Getwd fails")
	}
	if !strings.Contains(err.Error(), "boom") {
		t.Fatalf("error should propagate, got: %v", err)
	}
}

func TestAdd_DuplicateRootsAreDeduplicated(t *testing.T) {
	mock := &mockCaller{onCall: func(method string, params map[string]any) (any, error) { return nil, nil }}
	err := runAddWith(mock, addOptions{
		Name:         "foo",
		NoInput:      true,
		Here:         true,
		Projects:     []string{"/here", "/other"},
		Stdin:        strings.NewReader("v\n"),
		Stdout:       &bytes.Buffer{},
		Getwd:        stubGetwd("/here"),
		EvalSymlinks: identitySymlinks,
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range mock.calls {
		if c.Method != "vault.add" {
			continue
		}
		roots, _ := c.Params["roots"].([]string)
		if len(roots) != 2 {
			t.Fatalf("expected 2 unique roots, got %v", roots)
		}
	}
}
