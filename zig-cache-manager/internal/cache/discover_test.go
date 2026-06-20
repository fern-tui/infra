package cache

import "testing"

func lookupFrom(env map[string]string) envLookup {
	return func(key string) (string, bool) {
		v, ok := env[key]
		return v, ok
	}
}

func TestGlobalFallbackPrecedence(t *testing.T) {
	cases := []struct {
		name   string
		goos   string
		env    map[string]string
		want   string
		source string
		errOK  bool
	}{
		{
			name:   "explicit override wins on linux",
			goos:   "linux",
			env:    map[string]string{"ZIG_GLOBAL_CACHE_DIR": "/custom/cache", "HOME": "/home/x"},
			want:   "/custom/cache",
			source: "ZIG_GLOBAL_CACHE_DIR",
		},
		{
			name:   "explicit override wins on windows too",
			goos:   "windows",
			env:    map[string]string{"ZIG_GLOBAL_CACHE_DIR": `C:\custom`, "LOCALAPPDATA": `C:\Users\x\AppData\Local`},
			want:   `C:\custom`,
			source: "ZIG_GLOBAL_CACHE_DIR",
		},
		{
			name:   "windows uses LOCALAPPDATA",
			goos:   "windows",
			env:    map[string]string{"LOCALAPPDATA": `C:\Users\x\AppData\Local`},
			want:   `C:\Users\x\AppData\Local\zig`,
			source: `%LOCALAPPDATA%\zig`,
		},
		{
			name:   "linux prefers XDG_CACHE_HOME over HOME",
			goos:   "linux",
			env:    map[string]string{"XDG_CACHE_HOME": "/xdg", "HOME": "/home/x"},
			want:   "/xdg/zig",
			source: "$XDG_CACHE_HOME/zig",
		},
		{
			name:   "linux falls back to HOME/.cache/zig",
			goos:   "linux",
			env:    map[string]string{"HOME": "/home/x"},
			want:   "/home/x/.cache/zig",
			source: "$HOME/.cache/zig",
		},
		{
			// This is the case the original tool got wrong by relying on
			// Go's os.UserCacheDir, which returns ~/Library/Caches on
			// Darwin. Real zig has no Darwin special case.
			name:   "darwin uses the same XDG-style path as linux, not ~/Library/Caches",
			goos:   "darwin",
			env:    map[string]string{"HOME": "/Users/x"},
			want:   "/Users/x/.cache/zig",
			source: "$HOME/.cache/zig",
		},
		{
			name:  "linux with nothing set is an error",
			goos:  "linux",
			env:   map[string]string{},
			errOK: true,
		},
		{
			name:  "windows without LOCALAPPDATA is an error",
			goos:  "windows",
			env:   map[string]string{},
			errOK: true,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			path, source, err := globalFallback(c.goos, lookupFrom(c.env))
			if c.errOK {
				if err == nil {
					t.Fatalf("expected an error, got path=%q source=%q", path, source)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if path != c.want {
				t.Errorf("path = %q, want %q", path, c.want)
			}
			if source != c.source {
				t.Errorf("source = %q, want %q", source, c.source)
			}
		})
	}
}

func TestZonStringField(t *testing.T) {
	zon := []byte(`.{
    .zig_exe = "/usr/bin/zig",
    .lib_dir = "/usr/lib/zig",
    .global_cache_dir = "/home/user/.cache/zig",
    .version = "0.16.0",
}
`)
	got, ok := zonStringField(zon, "global_cache_dir")
	if !ok {
		t.Fatal("expected to find global_cache_dir")
	}
	if got != "/home/user/.cache/zig" {
		t.Errorf("got %q", got)
	}

	if _, ok := zonStringField(zon, "missing_field"); ok {
		t.Error("expected missing_field to not be found")
	}
}
