package cache

import (
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"sync"
	"time"
)

// Bucket is a top-level cache subdirectory:
//
//	h    cache-hash manifests
//	o    build output artifacts
//	z    cached ZIR for incremental compilation
//	tmp  transient dirs from interrupted builds
//	p    (global only) package-fetch tarballs
type Bucket string

const (
	BucketManifests Bucket = "h"
	BucketOutputs   Bucket = "o"
	BucketZIR       Bucket = "z"
	BucketTemp      Bucket = "tmp"
	BucketPackages  Bucket = "p"
	BucketOther     Bucket = "?"
)

func (b Bucket) Purpose() string {
	switch b {
	case BucketManifests:
		return "Cache-hash manifests"
	case BucketOutputs:
		return "Build output artifacts"
	case BucketZIR:
		return "Incremental compilation (ZIR) cache"
	case BucketTemp:
		return "Leftover temp dirs from interrupted runs"
	case BucketPackages:
		return "Downloaded package tarballs"
	default:
		return "Unrecognized entry"
	}
}

// Entry is one immediate child of a cache bucket directory (e.g. "o/c6ee5a122e4b3d8df174fc2bee24f16a").
type Entry struct {
	Bucket  Bucket
	Name    string // e.g. "c6ee5a122e4b3d8df174fc2bee24f16a"
	Path    string
	Size    int64  // total bytes of regular files under Path
	ModTime time.Time
}

// RelPath returns the bucket-qualified display path, e.g. "o/c6ee5a...".
func (e Entry) RelPath() string {
	return string(e.Bucket) + "/" + e.Name
}

type Result struct {
	Root      string
	Entries   []Entry
	TotalSize int64
	ByBucket  map[Bucket]*BucketStats
}

type BucketStats struct {
	Count int
	Size  int64
}

func knownBucket(name string) Bucket {
	switch name {
	case "h":
		return BucketManifests
	case "o":
		return BucketOutputs
	case "z":
		return BucketZIR
	case "tmp":
		return BucketTemp
	case "p":
		return BucketPackages
	default:
		return BucketOther
	}
}

// Scan walks root's bucket directories and measures each immediate child.
// Uses a bounded worker pool for parallel stat calls.
func Scan(root string) (*Result, error) {
	topLevel, err := os.ReadDir(root)
	if err != nil {
		return nil, err
	}

	type job struct {
		bucket Bucket
		name   string
		path   string
	}
	var jobs []job
	for _, item := range topLevel {
		if !item.IsDir() {
			continue // stray files directly at cache root (e.g. lock files)
		}
		bucket := knownBucket(item.Name())
		bucketPath := filepath.Join(root, item.Name())
		children, err := os.ReadDir(bucketPath)
		if err != nil {
			continue
		}
		for _, child := range children {
			jobs = append(jobs, job{bucket: bucket, name: child.Name(), path: filepath.Join(bucketPath, child.Name())})
		}
	}

	results := make([]Entry, len(jobs))
	workers := runtime.NumCPU()
	if workers > 16 {
		workers = 16
	}
	if workers < 1 {
		workers = 1
	}

	var wg sync.WaitGroup
	indices := make(chan int)
	go func() {
		for i := range jobs {
			indices <- i
		}
		close(indices)
	}()

	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range indices {
				j := jobs[i]
				size, modTime := measure(j.path)
				results[i] = Entry{
					Bucket:  j.bucket,
					Name:    j.name,
					Path:    j.path,
					Size:    size,
					ModTime: modTime,
				}
			}
		}()
	}
	wg.Wait()

	res := &Result{Root: root, ByBucket: map[Bucket]*BucketStats{}}
	for _, e := range results {
		res.Entries = append(res.Entries, e)
		res.TotalSize += e.Size
		stats := res.ByBucket[e.Bucket]
		if stats == nil {
			stats = &BucketStats{}
			res.ByBucket[e.Bucket] = stats
		}
		stats.Count++
		stats.Size += e.Size
	}

	sort.Slice(res.Entries, func(i, j int) bool {
		return res.Entries[i].Size > res.Entries[j].Size
	})

	return res, nil
}

// measure returns the total size of regular files under path and their latest modtime.
// Directory overhead is excluded to avoid inflating sizes.
func measure(path string) (size int64, modTime time.Time) {
	info, err := os.Lstat(path)
	if err != nil {
		return 0, time.Time{}
	}
	if !info.IsDir() {
		return info.Size(), info.ModTime()
	}

	sawFile := false
	_ = filepath.Walk(path, func(p string, fi os.FileInfo, err error) error {
		if err != nil || fi == nil || fi.IsDir() {
			return nil //nolint: keep scanning past unreadable entries
		}
		sawFile = true
		size += fi.Size()
		if fi.ModTime().After(modTime) {
			modTime = fi.ModTime()
		}
		return nil
	})
	if !sawFile {
		// empty dir: use its own mtime.
		modTime = info.ModTime()
	}
	return size, modTime
}
