package daemon

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	"tsm/internal/client"
	"tsm/internal/paths"
)

const (
	spawnTimeout = 10 * time.Second
	pollInterval = 50 * time.Millisecond
)

// EnsureRunning checks if tsmd is running. If not, spawns it.
// Returns the socket path.
func EnsureRunning() (string, error) {
	sockPath := paths.SocketPath()

	if client.IsSocketLive(sockPath) {
		return sockPath, nil
	}

	return spawn(sockPath)
}

// spawn starts tsmd and waits for its socket to become available.
func spawn(sockPath string) (string, error) {
	tsmdBin := tsmdPath()

	if _, err := os.Stat(tsmdBin); err != nil {
		return "", fmt.Errorf("tsmd not found at %s: %w", tsmdBin, err)
	}

	if err := os.MkdirAll(filepath.Dir(sockPath), 0o700); err != nil {
		return "", fmt.Errorf("create socket directory: %w", err)
	}

	os.Remove(sockPath)

	cmd := exec.Command(tsmdBin, "--socket", sockPath)

	// The daemon outlives this short-lived CLI. If it inherited our stdout/
	// stderr, those fds would stay open for the daemon's whole life — and an
	// agent harness (e.g. Claude Code's Bash tool) that waits for its command's
	// stdio pipes to reach EOF would hang forever on the first tsm call that
	// has to spawn the daemon. Redirect the daemon's output to its own log file
	// (or /dev/null), and never hand it our inherited fds. A nil Stdout/Stderr
	// makes os/exec connect the child to /dev/null, so the nil fallback is safe.
	if logw := daemonLogWriter(); logw != nil {
		cmd.Stdout = logw
		cmd.Stderr = logw
		defer logw.Close()
	}

	// Put the daemon in its own session so signals aimed at the CLI's process
	// group (Ctrl-C, the harness killing the foreground command) don't take it
	// down with them.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}

	if err := cmd.Start(); err != nil {
		return "", fmt.Errorf("start tsmd: %w", err)
	}

	// Readiness is the socket becoming live. We pass --socket explicitly, so
	// there's no need to read a path back from the daemon's stdout.
	if err := waitForSocket(sockPath, spawnTimeout); err != nil {
		cmd.Process.Kill()
		return "", fmt.Errorf("tsmd started but socket not ready within %s (see %s): %w", spawnTimeout, paths.DaemonLog(), err)
	}

	// Fully disown: we never wait on the daemon, and it has its own session.
	_ = cmd.Process.Release()

	return sockPath, nil
}

// daemonLogWriter opens the daemon log file for appending, falling back to
// /dev/null. It never returns the caller's stdio: the spawned daemon must not
// inherit fds that an agent harness is waiting on. Returns nil only if even
// /dev/null can't be opened, in which case the caller leaves Stdout/Stderr nil
// (os/exec then connects the child to /dev/null anyway).
func daemonLogWriter() *os.File {
	logPath := paths.DaemonLog()
	if err := os.MkdirAll(filepath.Dir(logPath), 0o700); err == nil {
		if f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600); err == nil {
			return f
		}
	}
	if f, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0); err == nil {
		return f
	}
	return nil
}

func waitForSocket(path string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if client.IsSocketLive(path) {
			return nil
		}
		time.Sleep(pollInterval)
	}
	return fmt.Errorf("socket %s not ready after %s", path, timeout)
}

func tsmdPath() string {
	if v := os.Getenv("TSM_TSMD_BIN"); v != "" {
		return v
	}
	return paths.TsmdBin()
}
