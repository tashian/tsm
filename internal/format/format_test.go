package format

import (
	"errors"
	"testing"
)

type fakeFormatter struct{ out []byte }

func (f *fakeFormatter) Format(value string, args []string) ([]byte, error) {
	return f.out, nil
}

func TestRegisterAndGet(t *testing.T) {
	f := &fakeFormatter{out: []byte("hello\n")}
	Register("fake-test-1", f)
	got, ok := Get("fake-test-1")
	if !ok {
		t.Fatal("expected Get to find registered formatter")
	}
	out, err := got.Format("ignored", nil)
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != "hello\n" {
		t.Fatalf("expected hello\\n, got %q", string(out))
	}
}

func TestGet_Unknown(t *testing.T) {
	_, ok := Get("does-not-exist")
	if ok {
		t.Fatal("expected Get to return ok=false for unknown formatter")
	}
}

type errFormatter struct{}

func (errFormatter) Format(value string, args []string) ([]byte, error) {
	return nil, errors.New("boom")
}

func TestFormatter_ErrorPropagates(t *testing.T) {
	Register("fake-test-2", errFormatter{})
	f, _ := Get("fake-test-2")
	_, err := f.Format("v", nil)
	if err == nil || err.Error() != "boom" {
		t.Fatalf("expected boom, got %v", err)
	}
}
