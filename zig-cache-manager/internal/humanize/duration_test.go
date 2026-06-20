package humanize

import (
	"testing"
	"time"
)

func TestFormatAge(t *testing.T) {
	cases := []struct {
		d    time.Duration
		want string
	}{
		{30 * time.Second, "30s"},
		{90 * time.Second, "1m"},
		{23 * time.Hour, "23h"},
		{25 * time.Hour, "1d"},
		{9 * 24 * time.Hour, "9d"},
		{40 * 24 * time.Hour, "1mo"},
		{400 * 24 * time.Hour, "1y"},
		{-5 * time.Second, "0s"}, // clamp negative (clock skew) to zero
	}
	for _, c := range cases {
		if got := FormatAge(c.d); got != c.want {
			t.Errorf("FormatAge(%v) = %q, want %q", c.d, got, c.want)
		}
	}
}

func TestParseDuration(t *testing.T) {
	cases := []struct {
		in   string
		want time.Duration
	}{
		{"", 0},
		{"30m", 30 * time.Minute},
		{"24h", 24 * time.Hour},
		{"1h30m", 90 * time.Minute},
		{"7d", 7 * 24 * time.Hour},
		{"2w", 14 * 24 * time.Hour},
		{"1.5d", 36 * time.Hour},
		{"0s", 0},
	}
	for _, c := range cases {
		got, err := ParseDuration(c.in)
		if err != nil {
			t.Errorf("ParseDuration(%q) returned error: %v", c.in, err)
			continue
		}
		if got != c.want {
			t.Errorf("ParseDuration(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestParseDurationErrors(t *testing.T) {
	for _, in := range []string{"abc", "-7d", "1d12h"} {
		if _, err := ParseDuration(in); err == nil {
			t.Errorf("ParseDuration(%q) expected an error, got none", in)
		}
	}
}
