package daemon

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
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
	cmd.Stderr = os.Stderr

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", fmt.Errorf("stdout pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return "", fmt.Errorf("start tsmd: %w", err)
	}

	scanner := bufio.NewScanner(stdout)
	done := make(chan string, 1)
	go func() {
		if scanner.Scan() {
			done <- scanner.Text()
		}
	}()

	select {
	case line := <-done:
		if line != "" {
			sockPath = line
		}
	case <-time.After(spawnTimeout):
		cmd.Process.Kill()
		return "", fmt.Errorf("tsmd did not print socket path within %s", spawnTimeout)
	}

	if err := waitForSocket(sockPath, spawnTimeout); err != nil {
		cmd.Process.Kill()
		return "", fmt.Errorf("tsmd started but socket not ready: %w", err)
	}

	go cmd.Wait()

	return sockPath, nil
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
