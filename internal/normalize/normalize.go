// Package normalize derives kebab-case secret ids from free-text display names.
package normalize

import (
	"errors"
	"strings"
	"unicode"
)

// Kebab lowercases s, replaces runs of non-alphanumeric ASCII characters with
// a single hyphen, and trims leading/trailing hyphens. Returns an error if the
// result is empty or longer than 128 characters.
func Kebab(s string) (string, error) {
	var b strings.Builder
	b.Grow(len(s))
	prevHyphen := true
	for _, r := range s {
		switch {
		case r >= 'A' && r <= 'Z':
			b.WriteRune(unicode.ToLower(r))
			prevHyphen = false
		case (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9'):
			b.WriteRune(r)
			prevHyphen = false
		default:
			if !prevHyphen {
				b.WriteByte('-')
				prevHyphen = true
			}
		}
	}
	out := strings.Trim(b.String(), "-")
	if out == "" {
		return "", errors.New("name must contain at least one alphanumeric character")
	}
	if len(out) > 128 {
		return "", errors.New("name must be 128 characters or fewer after normalization")
	}
	return out, nil
}
