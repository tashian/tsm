package jsonrpc

import "encoding/json"

// Request is a JSON-RPC 2.0 request.
type Request struct {
	JSONRPC string         `json:"jsonrpc"`
	Method  string         `json:"method"`
	Params  map[string]any `json:"params,omitempty"`
	ID      int            `json:"id"`
}

// Response is a JSON-RPC 2.0 response.
type Response struct {
	JSONRPC string          `json:"jsonrpc"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *RPCError       `json:"error,omitempty"`
	ID      int             `json:"id"`
}

// ResultInto unmarshals the result into v. Returns *RPCError if the response is an error.
func (r *Response) ResultInto(v any) error {
	if r.Error != nil {
		return r.Error
	}
	return json.Unmarshal(r.Result, v)
}

// RPCError is a JSON-RPC 2.0 error object.
type RPCError struct {
	Code    int            `json:"code"`
	Message string         `json:"message"`
	Data    map[string]any `json:"data,omitempty"`
}

func (e *RPCError) Error() string {
	return e.Message
}

// Well-known tsm error codes.
const (
	CodeVaultLocked      = -32001
	CodeAuthRequired     = -32002
	CodeSecretNotFound   = -32003
	CodeSecretOutOfScope = -32010
)
