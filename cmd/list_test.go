package cmd

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func listMock() *mockCaller {
	return &mockCaller{
		onCall: func(method string, params map[string]any) (any, error) {
			return []map[string]any{
				{"name": "anthropic-api-key", "display_name": "Anthropic API key", "description": "personal account", "confirm": true, "tags": []string{}},
				{"name": "anthropic-api-key-work", "display_name": "Anthropic API key (work)", "description": "", "confirm": true, "tags": []string{}},
				{"name": "openrouter-api-key", "display_name": "OpenRouter", "description": "", "confirm": false, "tags": []string{"llm"}},
				{"name": "gh-pat", "display_name": "GitHub PAT", "description": "Read-only token for private repos", "confirm": false, "tags": []string{"github"}},
			}, nil
		},
	}
}

func listJSON(t *testing.T, terms ...string) []string {
	t.Helper()
	prev := jsonFlag
	jsonFlag = true
	t.Cleanup(func() { jsonFlag = prev })

	var buf bytes.Buffer
	if err := runList(listMock(), terms, &buf); err != nil {
		t.Fatal(err)
	}
	var got []secretMetadata
	if err := json.Unmarshal(buf.Bytes(), &got); err != nil {
		t.Fatalf("invalid JSON: %s", buf.String())
	}
	names := []string{}
	for _, s := range got {
		names = append(names, s.Name)
	}
	return names
}

func TestList_NoTermsListsAll(t *testing.T) {
	if got := listJSON(t); len(got) != 4 {
		t.Errorf("expected 4 entries, got %v", got)
	}
}

func TestList_TermMatchesEveryField(t *testing.T) {
	cases := map[string]string{
		"OPENROUTER": "openrouter-api-key", // name, case-insensitive
		"github pat": "gh-pat",             // display name
		"private":    "gh-pat",             // description
		"llm":        "openrouter-api-key", // tag
	}
	for term, want := range cases {
		got := listJSON(t, term)
		if len(got) != 1 || got[0] != want {
			t.Errorf("term %q: got %v, want [%s]", term, got, want)
		}
	}
}

// Several terms match any of them, so one call can sweep synonyms
// ("aws amazon") instead of piping the full list into a filter.
func TestList_SeveralTermsMatchAny(t *testing.T) {
	got := listJSON(t, "github", "openrouter")
	if strings.Join(got, ",") != "openrouter-api-key,gh-pat" {
		t.Errorf("got %v", got)
	}
}

func TestList_ShowsEveryMatch(t *testing.T) {
	got := listJSON(t, "anthropic")
	if len(got) != 2 {
		t.Errorf("expected both Anthropic keys, got %v", got)
	}
}

func TestList_NoMatchJSONIsEmptyArray(t *testing.T) {
	prev := jsonFlag
	jsonFlag = true
	t.Cleanup(func() { jsonFlag = prev })

	var buf bytes.Buffer
	if err := runList(listMock(), []string{"stripe"}, &buf); err != nil {
		t.Fatal(err)
	}
	if buf.String() != "[]\n" {
		t.Errorf("got %q, want %q", buf.String(), "[]\n")
	}
}

func TestList_NoMatchText(t *testing.T) {
	var buf bytes.Buffer
	if err := runList(listMock(), []string{"stripe"}, &buf); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(buf.String(), `No secrets match "stripe"`) {
		t.Errorf("got %q", buf.String())
	}
}
