package cmd

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

func TestList_DefaultDoesNotSendIncludeAll(t *testing.T) {
	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			if method == "vault.list" {
				if _, ok := params["include_all"]; ok {
					t.Fatalf("default list must not pass include_all; got params=%v", params)
				}
				return []secretMetadata{}, nil
			}
			return nil, nil
		},
	}
	if err := runListWith(mock, listOptions{Stdout: &bytes.Buffer{}}); err != nil {
		t.Fatal(err)
	}
}

func TestList_AllSendsIncludeAll(t *testing.T) {
	var sawIncludeAll bool
	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			if method == "vault.list" {
				if v, ok := params["include_all"]; ok && v == true {
					sawIncludeAll = true
				}
				return []secretMetadata{}, nil
			}
			return nil, nil
		},
	}
	if err := runListWith(mock, listOptions{All: true, Stdout: &bytes.Buffer{}}); err != nil {
		t.Fatal(err)
	}
	if !sawIncludeAll {
		t.Fatal("--all should pass include_all=true to vault.list")
	}
}

func TestList_RendersScopeLineForProjectSecret(t *testing.T) {
	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			if method == "vault.list" {
				return []secretMetadata{
					{Name: "proj-key", Description: "test", Scope: "project", Roots: []string{"/Users/carl/code/foo"}},
				}, nil
			}
			return nil, nil
		},
	}
	var buf bytes.Buffer
	if err := runListWith(mock, listOptions{Stdout: &buf}); err != nil {
		t.Fatal(err)
	}
	out := buf.String()
	if !strings.Contains(out, "scope: project (/Users/carl/code/foo)") {
		t.Fatalf("expected scope line, got:\n%s", out)
	}
}

func TestList_GlobalSecretHasNoScopeLine(t *testing.T) {
	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			if method == "vault.list" {
				return []secretMetadata{
					{Name: "global-key", Description: "g", Scope: "global"},
				}, nil
			}
			return nil, nil
		},
	}
	var buf bytes.Buffer
	if err := runListWith(mock, listOptions{Stdout: &buf}); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(buf.String(), "scope:") {
		t.Fatalf("global secret should not render scope line; got:\n%s", buf.String())
	}
}

func TestList_PropagatesRPCError(t *testing.T) {
	mock := &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			return nil, errors.New("boom")
		},
	}
	err := runListWith(mock, listOptions{Stdout: &bytes.Buffer{}})
	if err == nil {
		t.Fatal("expected error to bubble up")
	}
}
