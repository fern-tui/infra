package cache

import (
	"testing"
	"time"
)

func entry(name string, size int64, age time.Duration, now time.Time) Entry {
	return Entry{Bucket: BucketOutputs, Name: name, Path: "o/" + name, Size: size, ModTime: now.Add(-age)}
}

func TestApplyOlderThan(t *testing.T) {
	now := time.Now()
	entries := []Entry{
		entry("fresh", 100, time.Hour, now),
		entry("stale", 100, 10*24*time.Hour, now),
	}
	plan := Apply(entries, Policy{OlderThan: 7 * 24 * time.Hour}, now)
	if len(plan.Evict) != 1 || plan.Evict[0].Name != "stale" {
		t.Fatalf("expected only 'stale' evicted, got %v", names(plan.Evict))
	}
	if len(plan.Keep) != 1 || plan.Keep[0].Name != "fresh" {
		t.Fatalf("expected 'fresh' kept, got %v", names(plan.Keep))
	}
}

func TestApplyMaxSizeEvictsOldestFirst(t *testing.T) {
	now := time.Now()
	// Three entries, 100 bytes each; oldest first should go to satisfy a
	// 150-byte cap, leaving the single newest entry.
	entries := []Entry{
		entry("oldest", 100, 3*time.Hour, now),
		entry("middle", 100, 2*time.Hour, now),
		entry("newest", 100, 1*time.Hour, now),
	}
	plan := Apply(entries, Policy{MaxSize: 150}, now)
	if len(plan.Keep) != 1 || plan.Keep[0].Name != "newest" {
		t.Fatalf("expected only 'newest' kept, got %v", names(plan.Keep))
	}
	if plan.EvictSize() != 200 {
		t.Errorf("EvictSize() = %d, want 200", plan.EvictSize())
	}
}

func TestApplyMaxSizeUnderCapEvictsNothing(t *testing.T) {
	now := time.Now()
	entries := []Entry{entry("a", 50, time.Hour, now), entry("b", 50, time.Hour, now)}
	plan := Apply(entries, Policy{MaxSize: 1000}, now)
	if len(plan.Evict) != 0 {
		t.Fatalf("expected nothing evicted, got %v", names(plan.Evict))
	}
}

func TestApplyCombinesAgeAndSize(t *testing.T) {
	now := time.Now()
	entries := []Entry{
		entry("very-old", 100, 30*24*time.Hour, now), // evicted by age
		entry("oldish", 100, 3*time.Hour, now),
		entry("newest", 100, 1*time.Hour, now),
	}
	// Age evicts very-old (100 bytes), leaving 200 bytes remaining.
	// MaxSize=150 then must evict one more (oldish) to get under cap.
	plan := Apply(entries, Policy{OlderThan: 24 * time.Hour, MaxSize: 150}, now)
	if len(plan.Keep) != 1 || plan.Keep[0].Name != "newest" {
		t.Fatalf("expected only 'newest' kept, got %v", names(plan.Keep))
	}
	if len(plan.Evict) != 2 {
		t.Fatalf("expected 2 entries evicted, got %v", names(plan.Evict))
	}
}

func TestApplyMaxCount(t *testing.T) {
	now := time.Now()
	entries := []Entry{
		entry("a", 10, 3*time.Hour, now),
		entry("b", 10, 2*time.Hour, now),
		entry("c", 10, 1*time.Hour, now),
	}
	plan := Apply(entries, Policy{MaxCount: 1}, now)
	if len(plan.Keep) != 1 || plan.Keep[0].Name != "c" {
		t.Fatalf("expected only 'c' (newest) kept, got %v", names(plan.Keep))
	}
}

func TestApplyBucketFilter(t *testing.T) {
	now := time.Now()
	e1 := entry("a", 10, 10*24*time.Hour, now)
	e2 := entry("b", 10, 10*24*time.Hour, now)
	e2.Bucket = BucketTemp
	plan := Apply([]Entry{e1, e2}, Policy{OlderThan: time.Hour, Bucket: BucketTemp}, now)
	if len(plan.Evict) != 1 || plan.Evict[0].Name != "b" {
		t.Fatalf("expected only the tmp-bucket entry considered, got %v", names(plan.Evict))
	}
}

func names(entries []Entry) []string {
	out := make([]string, len(entries))
	for i, e := range entries {
		out[i] = e.Name
	}
	return out
}
