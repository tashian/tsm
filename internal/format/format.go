// Package format provides built-in output formatters for tsm get --format.
//
// A Formatter takes a raw secret value plus optional inline arguments and
// returns the value reshaped for a specific consumer (env file line, AWS
// credential_process JSON, pgpass row, etc.).
package format

// Formatter reshapes a secret value into a wire format consumed by a
// specific tool. Implementations must not mutate the input value.
type Formatter interface {
	Format(value string, args []string) ([]byte, error)
}

var registry = map[string]Formatter{}

// Register adds a formatter under name. Last registration wins; intended to
// be called from per-formatter init() functions.
func Register(name string, f Formatter) {
	registry[name] = f
}

// Get returns the formatter registered under name and whether one exists.
func Get(name string) (Formatter, bool) {
	f, ok := registry[name]
	return f, ok
}
