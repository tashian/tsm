// Package runspec parses --env VAR=secret-name flag values for tsm run into
// validated mappings. The parser does not talk to the daemon — it only
// validates the syntactic shape and the character set of the names.
package runspec

import (
	"fmt"
	"regexp"
	"strings"
)

// Mapping is one --env flag value: an env var name paired with the tsm
// secret name to source its value from.
type Mapping struct {
	Var    string
	Secret string
}

var (
	envVarRE     = regexp.MustCompile(`^[A-Z_][A-Z0-9_]*$`)
	secretNameRE = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,128}$`)
)

// Parse consumes "VAR=secret-name" strings (in --env flag order) and
// returns the resulting mappings. Returns an error if any string is
// malformed or if a VAR appears more than once.
func Parse(specs []string) ([]Mapping, error) {
	out := make([]Mapping, 0, len(specs))
	seen := map[string]int{} // VAR -> 1-based index where first seen
	for i, s := range specs {
		idx := strings.IndexByte(s, '=')
		if idx < 0 {
			return nil, fmt.Errorf("--env[%d] %q: missing '=' separator (expected VAR=secret-name)", i, s)
		}
		v := s[:idx]
		name := s[idx+1:]
		if v == "" {
			return nil, fmt.Errorf("--env[%d] %q: VAR side is empty", i, s)
		}
		if name == "" {
			return nil, fmt.Errorf("--env[%d] %q: secret name side is empty", i, s)
		}
		if !envVarRE.MatchString(v) {
			return nil, fmt.Errorf("--env[%d] %q: invalid VAR %q (must match [A-Z_][A-Z0-9_]*)", i, s, v)
		}
		if !secretNameRE.MatchString(name) {
			return nil, fmt.Errorf("--env[%d] %q: invalid secret name %q (must match [a-zA-Z0-9_-]{1,128})", i, s, name)
		}
		if prev, ok := seen[v]; ok {
			return nil, fmt.Errorf("--env[%d] %q: VAR %q already specified at --env[%d]", i, s, v, prev-1)
		}
		seen[v] = i + 1
		out = append(out, Mapping{Var: v, Secret: name})
	}
	return out, nil
}

// UniqueSecrets returns the set of distinct secret names referenced by
// mappings, in first-seen order. Useful for de-duplicating vault.get calls
// when the same secret is bound to multiple env vars.
func UniqueSecrets(mappings []Mapping) []string {
	seen := map[string]bool{}
	out := make([]string, 0, len(mappings))
	for _, m := range mappings {
		if seen[m.Secret] {
			continue
		}
		seen[m.Secret] = true
		out = append(out, m.Secret)
	}
	return out
}
