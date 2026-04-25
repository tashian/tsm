package paths

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSocketPath_Default(t *testing.T) {
	t.Setenv("TSM_AUTH_SOCK", "")
	t.Setenv("XDG_RUNTIME_DIR", "")

	p := SocketPath()
	if p == "" {
		t.Fatal("SocketPath() returned empty string")
	}
	if !strings.HasSuffix(p, "tsm/vault.sock") {
		t.Fatalf("expected path ending in tsm/vault.sock, got %s", p)
	}
}

func TestSocketPath_EnvOverride(t *testing.T) {
	t.Setenv("TSM_AUTH_SOCK", "/tmp/custom.sock")
	p := SocketPath()
	if p != "/tmp/custom.sock" {
		t.Fatalf("expected /tmp/custom.sock, got %s", p)
	}
}

func TestVaultFile_Default(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", "")
	p := VaultFile()
	home, _ := os.UserHomeDir()
	expected := filepath.Join(home, ".local", "share", "tsm", "vault.enc")
	if p != expected {
		t.Fatalf("expected %s, got %s", expected, p)
	}
}

func TestVaultFile_XDG(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", "/tmp/xdg-data")
	p := VaultFile()
	expected := filepath.Join("/tmp/xdg-data", "tsm", "vault.enc")
	if p != expected {
		t.Fatalf("expected %s, got %s", expected, p)
	}
}

func TestConfigFile_Default(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", "")
	p := ConfigFile()
	home, _ := os.UserHomeDir()
	expected := filepath.Join(home, ".config", "tsm", "config.json")
	if p != expected {
		t.Fatalf("expected %s, got %s", expected, p)
	}
}

func TestAccessLog_Default(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", "")
	p := AccessLog()
	home, _ := os.UserHomeDir()
	expected := filepath.Join(home, ".local", "share", "tsm", "access.log")
	if p != expected {
		t.Fatalf("expected %s, got %s", expected, p)
	}
}
