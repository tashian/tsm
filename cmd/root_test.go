package cmd

import (
	"testing"
)

func TestRootCmd_HasAllSubcommands(t *testing.T) {
	root := NewRootCmd()
	expected := []string{
		"version", "status", "lock", "unlock",
		"ensure-daemon", "list", "init", "add",
		"get", "edit", "remove", "reset",
		"config", "log",
	}
	commands := make(map[string]bool)
	for _, c := range root.Commands() {
		commands[c.Name()] = true
	}
	for _, name := range expected {
		if !commands[name] {
			t.Errorf("missing subcommand: %s", name)
		}
	}
}

func TestRootCmd_HasJSONFlag(t *testing.T) {
	root := NewRootCmd()
	f := root.PersistentFlags().Lookup("json")
	if f == nil {
		t.Fatal("missing --json persistent flag")
	}
}

func TestVersionCmd_Output(t *testing.T) {
	Version = "1.2.3"
	root := NewRootCmd()
	root.SetArgs([]string{"version"})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
}
