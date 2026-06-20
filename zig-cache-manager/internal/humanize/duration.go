package humanize

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Age tier boundaries in seconds.
const (
	secsPerMinute = 60
	secsPerHour   = 60 * secsPerMinute
	secsPerDay    = 24 * secsPerHour
	secsPerMonth  = 30 * secsPerDay
	secsPerYear   = 365 * secsPerDay
)

// FormatAge renders d as a compact age string ("23h", "9d", "3mo").
// Note: zig doesn't update mtime on cache hits, so age = time since built.
func FormatAge(d time.Duration) string {
	secs := int64(d.Seconds())
	if secs < 0 {
		secs = 0
	}
	switch {
	case secs < secsPerMinute:
		return fmt.Sprintf("%ds", secs)
	case secs < secsPerHour:
		return fmt.Sprintf("%dm", secs/secsPerMinute)
	case secs < secsPerDay:
		return fmt.Sprintf("%dh", secs/secsPerHour)
	case secs < secsPerMonth:
		return fmt.Sprintf("%dd", secs/secsPerDay)
	case secs < secsPerYear:
		return fmt.Sprintf("%dmo", secs/secsPerMonth)
	default:
		return fmt.Sprintf("%dy", secs/secsPerYear)
	}
}

// ParseDuration parses "30m", "24h", "7d", "2w" into a duration.
// Empty string returns 0. Accepts d/w in addition to Go's built-in units;
// d/w cannot be combined ("36h" not "1d12h").
func ParseDuration(input string) (time.Duration, error) {
	s := strings.TrimSpace(input)
	if s == "" {
		return 0, nil
	}
	lower := strings.ToLower(s)

	if days, ok := parseLeadingFloat(lower, "d"); ok {
		return time.Duration(days * 24 * float64(time.Hour)), nil
	}
	if weeks, ok := parseLeadingFloat(lower, "w"); ok {
		return time.Duration(weeks * 7 * 24 * float64(time.Hour)), nil
	}

	d, err := time.ParseDuration(lower)
	if err != nil {
		return 0, fmt.Errorf("duration %q is not valid (want e.g. 30m, 24h, 7d, 2w): %w", input, err)
	}
	if d < 0 {
		return 0, fmt.Errorf("duration %q must not be negative", input)
	}
	return d, nil
}

func parseLeadingFloat(lower, suffix string) (float64, bool) {
	if !strings.HasSuffix(lower, suffix) {
		return 0, false
	}
	numPart := strings.TrimSuffix(lower, suffix)
	if numPart == "" {
		return 0, false
	}
	value, err := strconv.ParseFloat(numPart, 64)
	if err != nil || value < 0 {
		return 0, false
	}
	return value, true
}
