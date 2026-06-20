package cache

import (
	"sort"
	"time"
)

// Policy describes which entries clean should evict.
// Zero value on any field means no restriction on that dimension.
type Policy struct {
	OlderThan time.Duration // evict entries last written before now-OlderThan
	MaxSize   int64         // evict oldest entries until total size <= MaxSize
	MaxCount  int           // evict oldest entries until count <= MaxCount
	Bucket    Bucket        // restrict to one bucket ("" = all buckets)
}

// Plan is the result of applying a Policy to a set of entries.
type Plan struct {
	Evict []Entry
	Keep  []Entry
}

func (p Plan) EvictSize() int64 {
	var total int64
	for _, e := range p.Evict {
		total += e.Size
	}
	return total
}

// Apply computes which entries a Policy would evict, without touching the filesystem.
// Age eviction runs first; size/count caps then trim oldest-remaining as needed.
func Apply(entries []Entry, policy Policy, now time.Time) Plan {
	var candidates []Entry
	for _, e := range entries {
		if policy.Bucket != "" && e.Bucket != policy.Bucket {
			continue
		}
		candidates = append(candidates, e)
	}

	evict := make(map[string]bool, len(candidates))

	if policy.OlderThan > 0 {
		for _, e := range candidates {
			if now.Sub(e.ModTime) >= policy.OlderThan {
				evict[e.Path] = true
			}
		}
	}

	remaining := remainingOldestFirst(candidates, evict)

	if policy.MaxSize > 0 {
		var total int64
		for _, e := range remaining {
			total += e.Size
		}
		i := 0
		for total > policy.MaxSize && i < len(remaining) {
			evict[remaining[i].Path] = true
			total -= remaining[i].Size
			i++
		}
		remaining = remaining[i:]
	}

	if policy.MaxCount > 0 {
		i := 0
		for len(remaining)-i > policy.MaxCount {
			evict[remaining[i].Path] = true
			i++
		}
	}

	var plan Plan
	for _, e := range candidates {
		if evict[e.Path] {
			plan.Evict = append(plan.Evict, e)
		} else {
			plan.Keep = append(plan.Keep, e)
		}
	}
	sort.Slice(plan.Evict, func(i, j int) bool { return plan.Evict[i].Size > plan.Evict[j].Size })
	sort.Slice(plan.Keep, func(i, j int) bool { return plan.Keep[i].Size > plan.Keep[j].Size })
	return plan
}

func remainingOldestFirst(candidates []Entry, evict map[string]bool) []Entry {
	remaining := make([]Entry, 0, len(candidates))
	for _, e := range candidates {
		if !evict[e.Path] {
			remaining = append(remaining, e)
		}
	}
	sort.Slice(remaining, func(i, j int) bool { return remaining[i].ModTime.Before(remaining[j].ModTime) })
	return remaining
}
