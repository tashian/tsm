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
