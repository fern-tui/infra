package cache

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// Global resolves the global zig cache directory.
// Tries `zig env` first; falls back to ZIG_GLOBAL_CACHE_DIR or a platform default.
func Global() (path, source string, err error) {
	if dir, ok := globalFromZigEnv(); ok {
		return dir, "zig env", nil
	}
	return globalFallback(runtime.GOOS, os.LookupEnv)
}

// globalFromZigEnv shells out to `zig env` and extracts global_cache_dir.
// As of Zig 0.16.0, `zig env` outputs ZON, not JSON.
func globalFromZigEnv() (string, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	out, err := exec.CommandContext(ctx, "zig", "env").Output()
	if err != nil {
		return "", false
	}
	value, ok := zonStringField(out, "global_cache_dir")
	if !ok || value == "" {
		return "", false
	}
	return value, true
}

// envLookup is os.LookupEnv's signature, used to inject env in tests.
type envLookup func(key string) (string, bool)

// globalFallback mirrors introspect.resolveGlobalCacheDir from the zig source.
// macOS uses XDG (~/.cache/zig), not ~/Library/Caches.
// Uses explicit separators (not filepath.Join) so goos controls output in tests.
func globalFallback(goos string, lookup envLookup) (path, source string, err error) {
	if v, ok := lookup("ZIG_GLOBAL_CACHE_DIR"); ok {
		return v, "ZIG_GLOBAL_CACHE_DIR", nil
	}

	if goos == "windows" {
		if v, ok := lookup("LOCALAPPDATA"); ok && v != "" {
			return strings.TrimRight(v, `\/`) + `\zig`, `%LOCALAPPDATA%\zig`, nil
		}
		return "", "", errors.New("LOCALAPPDATA is not set; cannot determine the global zig cache directory")
	}

	if v, ok := lookup("XDG_CACHE_HOME"); ok && v != "" {
		return strings.TrimRight(v, "/") + "/zig", "$XDG_CACHE_HOME/zig", nil
	}
	if v, ok := lookup("HOME"); ok && v != "" {
		return strings.TrimRight(v, "/") + "/.cache/zig", "$HOME/.cache/zig", nil
	}
	return "", "", errors.New("neither XDG_CACHE_HOME nor HOME is set; cannot determine the global zig cache directory")
}

// Local resolves the project-local .zig-cache directory by walking upward
// for build.zig, mirroring zig's own discovery. ZIG_LOCAL_CACHE_DIR overrides.
// Falls back to startDir itself if no build.zig is found.
func Local(startDir string) (path string, found bool, err error) {
	if override, ok := os.LookupEnv("ZIG_LOCAL_CACHE_DIR"); ok && override != "" {
		info, statErr := os.Stat(override)
		return override, statErr == nil && info.IsDir(), nil
	}

	base := startDir
	if root, ok := findBuildRoot(startDir); ok {
		base = root
	}

	candidate := filepath.Join(base, ".zig-cache")
	info, statErr := os.Stat(candidate)
	if statErr != nil {
		if os.IsNotExist(statErr) {
			return candidate, false, nil
		}
		return candidate, false, statErr
	}
	return candidate, info.IsDir(), nil
}

// findBuildRoot walks upward from dir looking for a build.zig file,
// mirroring findBuildRoot in the zig compiler's src/main.zig.
func findBuildRoot(dir string) (root string, found bool) {
	current := dir
	for {
		if info, err := os.Stat(filepath.Join(current, "build.zig")); err == nil && !info.IsDir() {
			return current, true
		}
		parent := filepath.Dir(current)
		if parent == current {
			return "", false
		}
		current = parent
	}
}

// zonStringField extracts a `.field = "value"` string from `zig env` ZON output.
// Not a general ZON parser; a line scan is more version-stable.
func zonStringField(data []byte, field string) (string, bool) {
	prefix := "." + field
	for _, rawLine := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(rawLine)
		if !strings.HasPrefix(line, prefix) {
			continue
		}
		// Guard against `field` being a prefix of some other field name.
		if tail := line[len(prefix):]; tail != "" && tail[0] != ' ' && tail[0] != '=' {
			continue
		}

		rest := strings.TrimSpace(line[len(prefix):])
		rest = strings.TrimPrefix(rest, "=")
		first := strings.IndexByte(rest, '"')
		last := strings.LastIndexByte(rest, '"')
		if first == -1 || last <= first {
			continue
		}
		return unescapeZonString(rest[first+1 : last]), true
	}
	return "", false
}

// unescapeZonString handles backslash escapes in ZON string values.
func unescapeZonString(s string) string {
	if !strings.ContainsRune(s, '\\') {
		return s
	}
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '\\' && i+1 < len(s) {
			i++
			switch s[i] {
			case 'n':
				b.WriteByte('\n')
			case 't':
				b.WriteByte('\t')
			case 'r':
				b.WriteByte('\r')
			case '"':
				b.WriteByte('"')
			case '\\':
				b.WriteByte('\\')
			default:
				b.WriteByte('\\')
				b.WriteByte(s[i])
			}
			continue
		}
		b.WriteByte(c)
	}
	return b.String()
}
