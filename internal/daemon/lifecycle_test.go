package daemon

import (
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"tsm/internal/client"
)

// fakeTsmdScript stands in for the real daemon: it binds the requested unix
// socket, writes a marker to stderr, records its pid next to the socket, and
// stays alive — enough to exercise spawn()'s stdio redirection and detachment
// without needing the Swift binary.
const fakeTsmdScript = `#!/usr/bin/env python3
import os, socket, sys, threading, time
sock = None
a = sys.argv[1:]
for i, v in enumerate(a):
    if v == "--socket":
        sock = a[i + 1]
sys.stderr.write("FAKE_TSMD_STDERR_MARKER\n")
sys.stderr.flush()
with open(sock + ".pid", "w") as f:
    f.write(str(os.getpid()))
try:
    os.unlink(sock)
except FileNotFoundError:
    pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sock)
s.listen(16)
def serve():
    while True:
        try:
            conn, _ = s.accept()
            conn.close()
        except OSError:
            break
threading.Thread(target=serve, daemon=True).start()
time.sleep(30)
`

// TestSpawn_RedirectsDaemonStdioToLogAndDetaches verifies the two properties
// that keep an agent harness from hanging on the first tsm call: the spawned
// daemon's output goes to its log file (not the caller's inherited stdio), and
// the daemon runs in its own session.
func TestSpawn_RedirectsDaemonStdioToLogAndDetaches(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 not available")
	}
	dir := shortTempDir(t)
	sock := filepath.Join(dir, "vault.sock")

	fake := filepath.Join(dir, "tsmd")
	if err := os.WriteFile(fake, []byte(fakeTsmdScript), 0o755); err != nil {
		t.Fatal(err)
	}

	t.Setenv("TSM_AUTH_SOCK", sock)
	t.Setenv("TSM_TSMD_BIN", fake)
	t.Setenv("XDG_DATA_HOME", dir) // paths.DaemonLog() => dir/tsm/tsmd.log

	t.Cleanup(func() {
		if b, err := os.ReadFile(sock + ".pid"); err == nil {
			if pid, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil {
				syscall.Kill(pid, syscall.SIGKILL)
			}
		}
	})

	path, err := EnsureRunning()
	if err != nil {
		t.Fatalf("EnsureRunning: %v", err)
	}
	if !client.IsSocketLive(path) {
		t.Fatal("daemon socket not live after spawn")
	}

	// The daemon's stderr must land in the log file, not be inherited from the
	// caller — otherwise an agent harness waiting on its command's stdio pipes
	// hangs forever on the first spawn.
	logPath := filepath.Join(dir, "tsm", "tsmd.log")
	var logged bool
	for i := 0; i < 40; i++ {
		if b, _ := os.ReadFile(logPath); strings.Contains(string(b), "FAKE_TSMD_STDERR_MARKER") {
			logged = true
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !logged {
		t.Fatalf("daemon stderr marker not found in %s — stdio not redirected to log", logPath)
	}

	// The daemon must be detached into its own session (Setsid): a session
	// leader's process-group id equals its own pid.
	b, err := os.ReadFile(sock + ".pid")
	if err != nil {
		t.Fatalf("read pid file: %v", err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil {
		t.Fatalf("parse pid: %v", err)
	}
	pgid, err := syscall.Getpgid(pid)
	if err != nil {
		t.Fatalf("getpgid(%d): %v", pid, err)
	}
	if pgid != pid {
		t.Fatalf("daemon not session-detached: pgid=%d pid=%d (want equal)", pgid, pid)
	}
}

// shortTempDir returns a short-pathed temp directory, since macOS Unix sockets
// have a 104-char path limit and the default t.TempDir() under /var/folders/...
// often exceeds that.
func shortTempDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "tsm")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

func TestEnsureRunning_AlreadyRunning(t *testing.T) {
	dir := shortTempDir(t)
	sock := filepath.Join(dir, "vault.sock")

	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	t.Setenv("TSM_AUTH_SOCK", sock)

	path, err := EnsureRunning()
	if err != nil {
		t.Fatal(err)
	}
	if path != sock {
		t.Fatalf("expected %s, got %s", sock, path)
	}
}

func TestEnsureRunning_SpawnsDaemon(t *testing.T) {
	if os.Getenv("TSM_TEST_TSMD_BIN") == "" {
		t.Skip("set TSM_TEST_TSMD_BIN to a tsmd binary to run spawn tests")
	}

	dir := shortTempDir(t)
	sock := filepath.Join(dir, "vault.sock")
	t.Setenv("TSM_AUTH_SOCK", sock)
	t.Setenv("TSM_TSMD_BIN", os.Getenv("TSM_TEST_TSMD_BIN"))

	path, err := EnsureRunning()
	if err != nil {
		t.Fatal(err)
	}
	if !client.IsSocketLive(path) {
		t.Fatal("daemon socket is not live after EnsureRunning")
	}
}

func TestWaitForSocket_Existing(t *testing.T) {
	dir := shortTempDir(t)
	sock := filepath.Join(dir, "vault.sock")

	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	err = waitForSocket(sock, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
}

func TestWaitForSocket_Timeout(t *testing.T) {
	err := waitForSocket("/tmp/nonexistent-tsm-test.sock", 100*time.Millisecond)
	if err == nil {
		t.Fatal("expected timeout error")
	}
}

func TestWaitForSocket_BecomesAvailable(t *testing.T) {
	dir := shortTempDir(t)
	sock := filepath.Join(dir, "vault.sock")

	go func() {
		time.Sleep(200 * time.Millisecond)
		ln, err := net.Listen("unix", sock)
		if err != nil {
			return
		}
		defer ln.Close()
		time.Sleep(5 * time.Second)
	}()

	err := waitForSocket(sock, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
}
