package normalize

import (
	"strings"
	"testing"
)

func TestKebab(t *testing.T) {
	cases := []struct {
		in, want string
		wantErr  bool
	}{
		{"openai-api-key", "openai-api-key", false},
		{"OpenAI API key", "openai-api-key", false},
		{"GitHub PAT", "github-pat", false},
		{"  GitHub  PAT  ", "github-pat", false},
		{"Carl's prod token!", "carl-s-prod-token", false},
		{"already-fine", "already-fine", false},
		{"a___b", "a-b", false},
		{"---OpenAI---", "openai", false},
		{"", "", true},
		{"   ", "", true},
		{"---", "", true},
		{"!!!", "", true},
		{strings.Repeat("a", 200), "", true},
	}
	for _, c := range cases {
		got, err := Kebab(c.in)
		if (err != nil) != c.wantErr {
			t.Errorf("Kebab(%q) err=%v wantErr=%v", c.in, err, c.wantErr)
			continue
		}
		if !c.wantErr && got != c.want {
			t.Errorf("Kebab(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestKebab_AtMaxLength(t *testing.T) {
	in := strings.Repeat("a", 128)
	got, err := Kebab(in)
	if err != nil {
		t.Fatal(err)
	}
	if got != in {
		t.Fatalf("want %q, got %q", in, got)
	}
}
