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
