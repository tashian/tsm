package format

import (
	"strings"
	"testing"
)

func TestAWSCredentialProcess_ValidJSON(t *testing.T) {
	f, ok := Get("aws-credential-process")
	if !ok {
		t.Fatal("aws-credential-process not registered")
	}
	in := `{"Version":1,"AccessKeyId":"AKIA...","SecretAccessKey":"abc","SessionToken":"tok","Expiration":"2030-01-01T00:00:00Z"}`
	out, err := f.Format(in, nil)
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != in {
		t.Fatalf("expected verbatim passthrough, got %q", string(out))
	}
}

func TestAWSCredentialProcess_MinimumKeys(t *testing.T) {
	f, _ := Get("aws-credential-process")
	in := `{"Version":1,"AccessKeyId":"AKIA","SecretAccessKey":"s"}`
	if _, err := f.Format(in, nil); err != nil {
		t.Fatalf("expected ok with minimum keys, got %v", err)
	}
}

func TestAWSCredentialProcess_NoArgsAllowed(t *testing.T) {
	f, _ := Get("aws-credential-process")
	in := `{"Version":1,"AccessKeyId":"AKIA","SecretAccessKey":"s"}`
	_, err := f.Format(in, []string{"unexpected"})
	if err == nil {
		t.Fatal("expected error when args provided")
	}
}

func TestAWSCredentialProcess_RejectsNonJSON(t *testing.T) {
	f, _ := Get("aws-credential-process")
	_, err := f.Format("not json", nil)
	if err == nil {
		t.Fatal("expected error on non-JSON input")
	}
}

func TestAWSCredentialProcess_RejectsMissingKeys(t *testing.T) {
	f, _ := Get("aws-credential-process")
	cases := []string{
		`{"AccessKeyId":"AKIA","SecretAccessKey":"s"}`,                  // missing Version
		`{"Version":1,"SecretAccessKey":"s"}`,                            // missing AccessKeyId
		`{"Version":1,"AccessKeyId":"AKIA"}`,                             // missing SecretAccessKey
		`{}`,
	}
	for _, in := range cases {
		_, err := f.Format(in, nil)
		if err == nil {
			t.Errorf("expected error for %q", in)
			continue
		}
		// Error should name what's missing or mention the expected shape.
		if !strings.Contains(err.Error(), "Version") &&
			!strings.Contains(err.Error(), "AccessKeyId") &&
			!strings.Contains(err.Error(), "SecretAccessKey") {
			t.Errorf("error for %q should name missing field, got: %v", in, err)
		}
	}
}

func TestAWSCredentialProcess_RejectsWrongVersion(t *testing.T) {
	f, _ := Get("aws-credential-process")
	in := `{"Version":2,"AccessKeyId":"AKIA","SecretAccessKey":"s"}`
	_, err := f.Format(in, nil)
	if err == nil {
		t.Fatal("expected error on Version != 1")
	}
}
