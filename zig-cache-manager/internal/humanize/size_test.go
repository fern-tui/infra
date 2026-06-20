package humanize

import "testing"

func TestFormatSize(t *testing.T) {
	cases := map[int64]string{
		0:                 "0 B",
		512:               "512 B",
		1024:              "1.0 KB",
		1536:              "1.5 KB",
		1 << 20:           "1.0 MB",
		1 << 30:           "1.0 GB",
		5 * (1 << 30):     "5.0 GB",
		1 << 40:           "1.0 TB",
	}
	for bytes, want := range cases {
		if got := FormatSize(bytes); got != want {
			t.Errorf("FormatSize(%d) = %q, want %q", bytes, got, want)
		}
	}
}

func TestParseSize(t *testing.T) {
	cases := []struct {
		in   string
		want int64
	}{
		{"", 0},
		{"0", 0},
		{"512", 512},
		{"1K", 1024},
		{"1KB", 1024},
		{"1KiB", 1024},
		{"1k", 1024},
		{"5G", 5 * (1 << 30)},
		{"5GB", 5 * (1 << 30)},
		{"1.5G", int64(1.5 * (1 << 30))},
		{"500M", 500 * (1 << 20)},
		{"1T", 1 << 40},
		{"2TB", 2 * (1 << 40)},
	}
	for _, c := range cases {
		got, err := ParseSize(c.in)
		if err != nil {
			t.Errorf("ParseSize(%q) returned error: %v", c.in, err)
			continue
		}
		if got != c.want {
			t.Errorf("ParseSize(%q) = %d, want %d", c.in, got, c.want)
		}
	}
}

func TestParseSizeErrors(t *testing.T) {
	for _, in := range []string{"abc", "-5G", "5XB", "G5"} {
		if _, err := ParseSize(in); err == nil {
			t.Errorf("ParseSize(%q) expected an error, got none", in)
		}
	}
}

func TestParseSizeRoundTrip(t *testing.T) {
	// "5G" must parse to exactly the byte count FormatSize would print
	// back as "5.0 GB" — the two must stay symmetric.
	got, err := ParseSize("5G")
	if err != nil {
		t.Fatal(err)
	}
	if FormatSize(got) != "5.0 GB" {
		t.Errorf("round trip broke: ParseSize(%q) -> %d -> FormatSize -> %q", "5G", got, FormatSize(got))
	}
}
