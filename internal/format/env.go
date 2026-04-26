package format

import (
	"fmt"
	"regexp"
)

var envVarRE = regexp.MustCompile(`^[A-Z_][A-Z0-9_]*$`)

type envFormatter struct{}

// Format emits "VAR=value\n". args must be exactly one element: VAR.
func (envFormatter) Format(value string, args []string) ([]byte, error) {
	if len(args) != 1 {
		return nil, fmt.Errorf("env formatter requires exactly one argument: VAR (got %d)", len(args))
	}
	v := args[0]
	if !envVarRE.MatchString(v) {
		return nil, fmt.Errorf("invalid env var name %q (must match [A-Z_][A-Z0-9_]*)", v)
	}
	return []byte(v + "=" + value + "\n"), nil
}

func init() {
	Register("env", envFormatter{})
}
