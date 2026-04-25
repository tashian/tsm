package client

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"sync"

	"tsm/internal/jsonrpc"
)

// Caller is the interface for making JSON-RPC calls. Commands depend on this
// for testability — tests inject a mock instead of a real socket client.
type Caller interface {
	Call(method string, params map[string]any, result any) error
	Close() error
}

// DaemonClient connects to tsmd over a Unix socket.
type DaemonClient struct {
	conn   net.Conn
	reader *bufio.Reader
	mu     sync.Mutex
	nextID int
}

// Dial connects to the daemon at the given Unix socket path.
func Dial(socketPath string) (*DaemonClient, error) {
	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		return nil, fmt.Errorf("cannot connect to daemon at %s: %w", socketPath, err)
	}
	return &DaemonClient{
		conn:   conn,
		reader: bufio.NewReader(conn),
		nextID: 1,
	}, nil
}

// Call sends a JSON-RPC request and unmarshals the response into result.
// Returns *jsonrpc.RPCError if the daemon returns an error response.
// If result is nil, the response result is discarded.
func (c *DaemonClient) Call(method string, params map[string]any, result any) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	req := jsonrpc.Request{
		JSONRPC: "2.0",
		Method:  method,
		Params:  params,
		ID:      c.nextID,
	}
	c.nextID++

	data, err := json.Marshal(req)
	if err != nil {
		return fmt.Errorf("marshal request: %w", err)
	}
	data = append(data, '\n')

	if _, err := c.conn.Write(data); err != nil {
		return fmt.Errorf("write request: %w", err)
	}

	line, err := c.reader.ReadBytes('\n')
	if err != nil {
		return fmt.Errorf("read response: %w", err)
	}

	var resp jsonrpc.Response
	if err := json.Unmarshal(line, &resp); err != nil {
		return fmt.Errorf("unmarshal response: %w", err)
	}

	if result == nil {
		if resp.Error != nil {
			return resp.Error
		}
		return nil
	}

	return resp.ResultInto(result)
}

// Close closes the connection.
func (c *DaemonClient) Close() error {
	return c.conn.Close()
}

// IsSocketLive checks if a Unix socket at the given path is accepting connections.
func IsSocketLive(path string) bool {
	conn, err := net.Dial("unix", path)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}
