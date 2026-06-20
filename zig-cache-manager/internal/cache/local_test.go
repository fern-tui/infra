package cache

import (
	"os"
	"path/filepath"
	"testing"
)

func TestFindBuildRootWalksUpward(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "build.zig"), []byte(""), 0o644); err != nil {
		t.Fatal(err)
	}
	nested := filepath.Join(root, "src", "deeper")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}

	got, found := findBuildRoot(nested)
	if !found {
		t.Fatal("expected to find build.zig")
	}
	if got != root {
		t.Errorf("findBuildRoot = %q, want %q", got, root)
	}
}

func TestFindBuildRootNotFound(t *testing.T) {
	// A temp dir has no build.zig anywhere above it (other than
	// potentially the real filesystem root, which won't have one either).
	dir := t.TempDir()
	if _, found := findBuildRoot(dir); found {
		t.Error("expected no build.zig to be found")
	}
}

func TestLocalFallsBackToCacheDirWithoutBuildZig(t *testing.T) {
	dir := t.TempDir()
	cacheDir := filepath.Join(dir, ".zig-cache")
	if err := os.Mkdir(cacheDir, 0o755); err != nil {
		t.Fatal(err)
	}

	path, found, err := Local(dir)
	if err != nil {
		t.Fatal(err)
	}
	if !found {
		t.Fatal("expected to find the orphaned .zig-cache directory")
	}
	if path != cacheDir {
		t.Errorf("path = %q, want %q", path, cacheDir)
	}
}

func TestLocalFindsCacheNextToBuildZig(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "build.zig"), []byte(""), 0o644); err != nil {
		t.Fatal(err)
	}
	cacheDir := filepath.Join(root, ".zig-cache")
	if err := os.Mkdir(cacheDir, 0o755); err != nil {
		t.Fatal(err)
	}
	nested := filepath.Join(root, "src")
	if err := os.Mkdir(nested, 0o755); err != nil {
		t.Fatal(err)
	}

	path, found, err := Local(nested)
	if err != nil {
		t.Fatal(err)
	}
	if !found {
		t.Fatal("expected to find .zig-cache via the build.zig search")
	}
	if path != cacheDir {
		t.Errorf("path = %q, want %q (running from a subdirectory should still find it)", path, cacheDir)
	}
}
