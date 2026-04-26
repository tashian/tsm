package format

import (
	"fmt"
	"strings"
)

type pgpassFormatter struct{}

// Format validates the value as a single pgpass line
// (host:port:database:username:password) and returns it verbatim.
// See https://www.postgresql.org/docs/current/libpq-pgpass.html
func (pgpassFormatter) Format(value string, args []string) ([]byte, error) {
	if len(args) != 0 {
		return nil, fmt.Errorf("pgpass formatter takes no arguments (got %d)", len(args))
	}
	if strings.ContainsRune(value, '\n') {
		return nil, fmt.Errorf("pgpass: value contains a newline; pgpass entries must be a single line")
	}
	if n := strings.Count(value, ":"); n != 4 {
		return nil, fmt.Errorf("pgpass: expected 5 colon-delimited fields (host:port:db:user:password), got %d colons", n)
	}
	return []byte(value), nil
}

func init() {
	Register("pgpass", pgpassFormatter{})
}
