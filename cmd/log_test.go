package cmd

import "testing"

func TestFormatLogLine_ShowsCommand(t *testing.T) {
	line := `{"ts":"2026-10-05T20:58:00Z","method":"vault.get","secret":"gh-pat","command":"gh pr list --repo tashian/tsm","result":"ok"}`
	want := "2026-10-05T20:58:00Z  vault.get      gh-pat  ok  gh pr list --repo tashian/tsm"
	if got := formatLogLine(line); got != want {
		t.Fatalf("got  %q\nwant %q", got, want)
	}
}

func TestFormatLogLine_OldLineWithClientID(t *testing.T) {
	line := `{"ts":"2026-01-01T00:00:00Z","method":"vault.get","secret":"k","client_id":"cli/pid:1","result":"ok"}`
	want := "2026-01-01T00:00:00Z  vault.get      k  ok"
	if got := formatLogLine(line); got != want {
		t.Fatalf("got  %q\nwant %q", got, want)
	}
}

func TestFormatLogLine_NoSecretNoCommand(t *testing.T) {
	line := `{"ts":"T","method":"vault.lock","secret":null,"command":null,"result":"ok"}`
	want := "T  vault.lock      ok"
	if got := formatLogLine(line); got != want {
		t.Fatalf("got  %q\nwant %q", got, want)
	}
}

func TestFormatLogLine_InvalidJSONUnchanged(t *testing.T) {
	if got := formatLogLine("not json"); got != "not json" {
		t.Fatalf("got %q", got)
	}
}
