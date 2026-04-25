package jsonrpc

import (
	"encoding/json"
	"testing"
)

func TestRequest_Marshal(t *testing.T) {
	req := Request{
		JSONRPC: "2.0",
		Method:  "vault.status",
		ID:      1,
	}
	data, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	json.Unmarshal(data, &m)
	if m["method"] != "vault.status" {
		t.Fatalf("expected vault.status, got %v", m["method"])
	}
	if m["jsonrpc"] != "2.0" {
		t.Fatalf("expected 2.0, got %v", m["jsonrpc"])
	}
}

func TestRequest_MarshalWithParams(t *testing.T) {
	req := Request{
		JSONRPC: "2.0",
		Method:  "vault.get",
		Params:  map[string]any{"name": "my_secret"},
		ID:      1,
	}
	data, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	json.Unmarshal(data, &m)
	params := m["params"].(map[string]any)
	if params["name"] != "my_secret" {
		t.Fatalf("expected my_secret, got %v", params["name"])
	}
}

func TestRequest_MarshalOmitsNilParams(t *testing.T) {
	req := Request{
		JSONRPC: "2.0",
		Method:  "vault.lock",
		ID:      1,
	}
	data, _ := json.Marshal(req)
	var m map[string]any
	json.Unmarshal(data, &m)
	if _, ok := m["params"]; ok {
		t.Fatal("expected params to be omitted when nil")
	}
}

func TestResponse_UnmarshalSuccess(t *testing.T) {
	raw := `{"jsonrpc":"2.0","result":{"locked":false,"ttl_remaining_seconds":3600,"secret_count":2},"id":1}`
	var resp Response
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Error != nil {
		t.Fatal("expected no error")
	}
	if resp.Result == nil {
		t.Fatal("expected result")
	}
}

func TestResponse_UnmarshalError(t *testing.T) {
	raw := `{"jsonrpc":"2.0","error":{"code":-32001,"message":"Vault is locked","data":{"auth_method":"touchid"}},"id":1}`
	var resp Response
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Error == nil {
		t.Fatal("expected error")
	}
	if resp.Error.Code != -32001 {
		t.Fatalf("expected -32001, got %d", resp.Error.Code)
	}
	if resp.Error.Message != "Vault is locked" {
		t.Fatalf("expected 'Vault is locked', got %s", resp.Error.Message)
	}
}

func TestRPCError_Error(t *testing.T) {
	e := &RPCError{Code: -32001, Message: "Vault is locked"}
	s := e.Error()
	if s != "Vault is locked" {
		t.Fatalf("expected 'Vault is locked', got %s", s)
	}
}

func TestResponse_ResultInto(t *testing.T) {
	raw := `{"jsonrpc":"2.0","result":{"locked":false,"ttl_remaining_seconds":3600,"secret_count":2},"id":1}`
	var resp Response
	json.Unmarshal([]byte(raw), &resp)

	var status struct {
		Locked              bool `json:"locked"`
		TTLRemainingSeconds int  `json:"ttl_remaining_seconds"`
		SecretCount         int  `json:"secret_count"`
	}
	if err := resp.ResultInto(&status); err != nil {
		t.Fatal(err)
	}
	if status.Locked {
		t.Fatal("expected unlocked")
	}
	if status.TTLRemainingSeconds != 3600 {
		t.Fatalf("expected 3600, got %d", status.TTLRemainingSeconds)
	}
	if status.SecretCount != 2 {
		t.Fatalf("expected 2, got %d", status.SecretCount)
	}
}

func TestResponse_ResultInto_Error(t *testing.T) {
	raw := `{"jsonrpc":"2.0","error":{"code":-32001,"message":"Vault is locked"},"id":1}`
	var resp Response
	json.Unmarshal([]byte(raw), &resp)

	var status struct{}
	err := resp.ResultInto(&status)
	if err == nil {
		t.Fatal("expected error")
	}
	rpcErr, ok := err.(*RPCError)
	if !ok {
		t.Fatalf("expected *RPCError, got %T", err)
	}
	if rpcErr.Code != -32001 {
		t.Fatalf("expected -32001, got %d", rpcErr.Code)
	}
}
