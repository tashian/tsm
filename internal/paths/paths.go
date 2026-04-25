package paths

import (
	"os"
	"path/filepath"
)

// SocketPath returns the Unix socket path for the daemon.
// Precedence: $TSM_AUTH_SOCK > $XDG_RUNTIME_DIR/tsm/vault.sock > $TMPDIR/tsm/vault.sock
func SocketPath() string {
	if v := os.Getenv("TSM_AUTH_SOCK"); v != "" {
		return v
	}
	if v := os.Getenv("XDG_RUNTIME_DIR"); v != "" {
		return filepath.Join(v, "tsm", "vault.sock")
	}
	return filepath.Join(os.TempDir(), "tsm", "vault.sock")
}

// VaultFile returns the path to the encrypted vault file.
func VaultFile() string {
	return filepath.Join(dataDir(), "vault.enc")
}

// AccessLog returns the path to the access log file.
func AccessLog() string {
	return filepath.Join(dataDir(), "access.log")
}

// ConfigFile returns the path to the config file.
func ConfigFile() string {
	return filepath.Join(configDir(), "config.json")
}

// TsmdBin returns the expected path to the tsmd binary.
// Looks in the same directory as the running tsm binary first,
// then falls back to ~/.local/bin/tsmd.
func TsmdBin() string {
	if exe, err := os.Executable(); err == nil {
		candidate := filepath.Join(filepath.Dir(exe), "tsmd")
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "bin", "tsmd")
}

func dataDir() string {
	if v := os.Getenv("XDG_DATA_HOME"); v != "" {
		return filepath.Join(v, "tsm")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "share", "tsm")
}

func configDir() string {
	if v := os.Getenv("XDG_CONFIG_HOME"); v != "" {
		return filepath.Join(v, "tsm")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "tsm")
}
