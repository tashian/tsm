package daemon

import (
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"tsm/internal/client"
)

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
