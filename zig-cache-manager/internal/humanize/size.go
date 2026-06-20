// Package humanize converts between machine values (bytes, durations) and
// the human-friendly strings used in zcm's UI and flags.
package humanize

import (
	"fmt"
	"strconv"
	"strings"
)

const (
	kb = 1 << 10
	mb = 1 << 20
	gb = 1 << 30
	tb = 1 << 40
)

// Longer suffixes listed first to avoid prefix mis-matches (GiB before G).
var sizeUnits = []struct {
	suffix     string
	multiplier float64
}{
	{"GIB", gb}, {"GB", gb}, {"G", gb},
	{"MIB", mb}, {"MB", mb}, {"M", mb},
	{"KIB", kb}, {"KB", kb}, {"K", kb},
	{"TIB", tb}, {"TB", tb}, {"T", tb},
	{"B", 1},
}

// FormatSize renders a byte count using binary units (1024-based), one decimal place.
func FormatSize(bytes int64) string {
	if bytes < 0 {
		bytes = 0
	}
	switch {
	case bytes < kb:
		return fmt.Sprintf("%d B", bytes)
	case bytes < mb:
		return fmt.Sprintf("%.1f KB", float64(bytes)/kb)
	case bytes < gb:
		return fmt.Sprintf("%.1f MB", float64(bytes)/mb)
	case bytes < tb:
		return fmt.Sprintf("%.1f GB", float64(bytes)/gb)
	default:
		return fmt.Sprintf("%.1f TB", float64(bytes)/tb)
	}
}

// ParseSize parses "5G", "512MB", "1.5GiB", or a bare byte count.
// Empty string returns 0 (callers use 0 for "no limit"). Units are 1024-based.
func ParseSize(input string) (int64, error) {
	s := strings.TrimSpace(input)
	if s == "" {
		return 0, nil
	}

	upper := strings.ToUpper(s)
	for _, unit := range sizeUnits {
		if !strings.HasSuffix(upper, unit.suffix) {
			continue
		}
		numPart := strings.TrimSpace(s[:len(s)-len(unit.suffix)])
		if numPart == "" {
			return 0, fmt.Errorf("size %q is missing a number before the unit", input)
		}
		value, err := strconv.ParseFloat(numPart, 64)
		if err != nil {
			return 0, fmt.Errorf("size %q is not a valid number with unit (want e.g. 512M, 5G, 1.5GiB): %w", input, err)
		}
		if value < 0 {
			return 0, fmt.Errorf("size %q must not be negative", input)
		}
		return int64(value * unit.multiplier), nil
	}

	// No unit suffix: require plain integer to catch typos.
	value, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("size %q is not valid (want a byte count or a suffix like 512M, 5G, 1T)", input)
	}
	if value < 0 {
		return 0, fmt.Errorf("size %q must not be negative", input)
	}
	return value, nil
}
