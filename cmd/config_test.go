package cmd

import (
	"testing"
	"time"
)

func TestParseTTLDuration(t *testing.T) {
	cases := []struct {
		in   string
		want int
		err  bool
	}{
		{"30m", 1800, false},
		{"1h", 3600, false},
		{"1h30m", 5400, false},
		{"90s", 90, false},
		{"500ms", 0, true},
		{"0", 0, true},
		{"-5m", 0, true},
		{"garbage", 0, true},
	}
	for _, c := range cases {
		got, err := parseTTLDuration(c.in)
		if c.err {
			if err == nil {
				t.Errorf("parseTTLDuration(%q): expected error, got %d", c.in, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("parseTTLDuration(%q): unexpected error %v", c.in, err)
			continue
		}
		if got != c.want {
			t.Errorf("parseTTLDuration(%q): got %d, want %d", c.in, got, c.want)
		}
	}
}

func TestFormatTTLSeconds(t *testing.T) {
	cases := []struct {
		in   int
		want string
	}{
		{1800, "30m0s"},
		{90, "1m30s"},
		{3600, "1h0m0s"},
		{5400, "1h30m0s"},
	}
	for _, c := range cases {
		got := formatTTLSeconds(c.in)
		if got != c.want {
			t.Errorf("formatTTLSeconds(%d): got %q, want %q", c.in, got, c.want)
		}
	}
}

func TestDurationRoundTrip(t *testing.T) {
	d, err := time.ParseDuration("30m")
	if err != nil || int(d.Seconds()) != 1800 {
		t.Fatalf("round-trip failed: %v %v", d, err)
	}
}
