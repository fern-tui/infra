package cache

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
)

// PurgeResult reports what was removed and what failed during a purge.
type PurgeResult struct {
	Removed       []Entry
	Failed        []FailedEntry
	ReclaimedSize int64
}

type FailedEntry struct {
	Entry Entry
	Err   error
}

// Purge deletes entries in parallel. ReclaimedSize counts only entries actually removed.
func Purge(entries []Entry) PurgeResult {
	type outcome struct {
		entry Entry
		err   error
	}
	outcomes := make([]outcome, len(entries))

	workers := runtime.NumCPU()
	if workers > 8 {
		workers = 8
	}
	if workers < 1 {
		workers = 1
	}

	var wg sync.WaitGroup
	indices := make(chan int)
	go func() {
		for i := range entries {
			indices <- i
		}
		close(indices)
	}()
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range indices {
				err := os.RemoveAll(entries[i].Path)
				outcomes[i] = outcome{entry: entries[i], err: err}
			}
		}()
	}
	wg.Wait()

	var result PurgeResult
	for _, o := range outcomes {
		if o.err != nil {
			result.Failed = append(result.Failed, FailedEntry{Entry: o.entry, Err: o.err})
			continue
		}
		result.Removed = append(result.Removed, o.entry)
		result.ReclaimedSize += o.entry.Size
	}
	return result
}

// Nuke deletes an entire cache directory.
// Refuses unsafe paths (fs root, home dir, or anything not resembling a zig cache).
func Nuke(path string) error {
	if err := checkSafeToDelete(path); err != nil {
		return err
	}
	return os.RemoveAll(path)
}

func checkSafeToDelete(path string) error {
	abs, err := filepath.Abs(path)
	if err != nil {
		return fmt.Errorf("could not resolve %q to an absolute path: %w", path, err)
	}
	clean := filepath.Clean(abs)

	if isRootPath(clean) {
		return fmt.Errorf("refusing to delete %q: that's a filesystem root", clean)
	}
	if home, err := os.UserHomeDir(); err == nil && home != "" && clean == filepath.Clean(home) {
		return fmt.Errorf("refusing to delete %q: that's your home directory", clean)
	}

	base := strings.ToLower(filepath.Base(clean))
	looksLikeCache := base == "zig" || base == ".zig-cache" || base == "zig-cache" ||
		strings.Contains(base, "zig-cache")
	depth := len(strings.Split(filepath.ToSlash(clean), "/"))
	if !looksLikeCache && depth <= 2 {
		return fmt.Errorf(
			"refusing to delete %q: it doesn't look like a zig cache directory "+
				"(expected a path ending in .zig-cache or zig) and is suspiciously close to the filesystem root; "+
				"pass --cache-dir only when you're sure", clean)
	}
	return nil
}

func isRootPath(p string) bool {
	parent := filepath.Dir(p)
	return parent == p
}
