package format

import (
	"encoding/json"
	"fmt"
)

type awsCredentialProcess struct{}

// Format validates the value as AWS credential_process JSON and returns it
// verbatim. The wire format is defined by AWS; we do not reshape it.
//
// Required keys: Version (must be 1), AccessKeyId, SecretAccessKey.
// SessionToken and Expiration are optional and pass through.
func (awsCredentialProcess) Format(value string, args []string) ([]byte, error) {
	if len(args) != 0 {
		return nil, fmt.Errorf("aws-credential-process formatter takes no arguments (got %d)", len(args))
	}
	var probe struct {
		Version         *int    `json:"Version"`
		AccessKeyId     *string `json:"AccessKeyId"`
		SecretAccessKey *string `json:"SecretAccessKey"`
	}
	if err := json.Unmarshal([]byte(value), &probe); err != nil {
		return nil, fmt.Errorf("aws-credential-process: secret value is not valid JSON: %w", err)
	}
	if probe.Version == nil {
		return nil, fmt.Errorf(`aws-credential-process: missing required key "Version"`)
	}
	if *probe.Version != 1 {
		return nil, fmt.Errorf("aws-credential-process: Version must be 1, got %d", *probe.Version)
	}
	if probe.AccessKeyId == nil {
		return nil, fmt.Errorf(`aws-credential-process: missing required key "AccessKeyId"`)
	}
	if probe.SecretAccessKey == nil {
		return nil, fmt.Errorf(`aws-credential-process: missing required key "SecretAccessKey"`)
	}
	return []byte(value), nil
}

func init() {
	Register("aws-credential-process", awsCredentialProcess{})
}
