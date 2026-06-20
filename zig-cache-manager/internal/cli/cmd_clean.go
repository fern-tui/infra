package cli

import (
	"flag"
	"fmt"
	"time"

	"zig-cache-manager/internal/cache"
	"zig-cache-manager/internal/humanize"
	"zig-cache-manager/internal/ui"
)

func cmdClean(args []string, env Env) int {
	var common CommonFlags
	var olderThanStr, maxSizeStr, bucketFilter string
	var maxCount int
	var dryRun, yes bool

	fs := flag.NewFlagSet("clean", flag.ExitOnError)
	fs.SetOutput(env.Stderr)
	bindCommon(fs, &common)
	fs.StringVar(&olderThanStr, "older-than", "", "evict entries last written before this long ago (e.g. 7d, 24h, 2w)")
	fs.StringVar(&maxSizeStr, "max-size", "", "evict oldest entries until the cache is under this size (e.g. 5G, 500M)")
	fs.IntVar(&maxCount, "max-count", 0, "evict oldest entries until at most this many remain")
	fs.StringVar(&bucketFilter, "bucket", "", "only consider entries from this bucket (h, o, z, tmp, p)")
	fs.BoolVar(&dryRun, "dry-run", false, "show what would be removed without deleting anything")
	fs.BoolVar(&dryRun, "n", false, "shorthand for --dry-run")
	fs.BoolVar(&yes, "yes", false, "don't prompt for confirmation")
	fs.BoolVar(&yes, "y", false, "shorthand for --yes")
	fs.Usage = func() { printHelpFor("clean", env.Stdout) }
	fs.Parse(args)

	if olderThanStr == "" && maxSizeStr == "" && maxCount == 0 {
		fmt.Fprintln(env.Stderr, "zcm: clean needs at least one of --older-than, --max-size, --max-count")
		fmt.Fprintln(env.Stderr, "\nRun 'zcm clean --help' for examples.")
		return 2
	}

	olderThan, err := humanize.ParseDuration(olderThanStr)
	if err != nil {
		fmt.Fprintf(env.Stderr, "zcm: %v\n", err)
		return 2
	}
	maxSize, err := humanize.ParseSize(maxSizeStr)
	if err != nil {
		fmt.Fprintf(env.Stderr, "zcm: %v\n", err)
		return 2
	}

	target, err := resolveTarget(common)
	if err != nil {
		fmt.Fprintf(env.Stderr, "zcm: %v\n", err)
		return 1
	}
	result, err := cache.Scan(target.Path)
	if err != nil {
		fmt.Fprintf(env.Stderr, "zcm: could not scan %s: %v\n", target.Path, err)
		return 1
	}

	plan := cache.Apply(result.Entries, cache.Policy{
		OlderThan: olderThan,
		MaxSize:   maxSize,
		MaxCount:  maxCount,
		Bucket:    cache.Bucket(bucketFilter),
	}, time.Now())

	if common.JSON {
		type cleanJSON struct {
			Path       string      `json:"path"`
			DryRun     bool        `json:"dry_run"`
			EvictCount int         `json:"evict_count"`
			EvictBytes int64       `json:"evict_bytes"`
			KeepCount  int         `json:"keep_count"`
			Entries    []entryJSON `json:"entries"`
		}
		out := cleanJSON{Path: target.Path, DryRun: dryRun, EvictCount: len(plan.Evict), EvictBytes: plan.EvictSize(), KeepCount: len(plan.Keep)}
		now := time.Now()
		for _, e := range plan.Evict {
			out.Entries = append(out.Entries, entryJSON{
				Entry: e.RelPath(), Bucket: string(e.Bucket), SizeBytes: e.Size,
					     AgeSeconds: int64(now.Sub(e.ModTime).Seconds()), ModifiedAt: e.ModTime.Format(time.RFC3339),
			})
		}
		if !dryRun {
			purged := cache.Purge(plan.Evict)
			out.EvictCount = len(purged.Removed)
			out.EvictBytes = purged.ReclaimedSize
		}
		return printJSON(env.Stdout, out)
	}

	u := ui.New(env.Stdout, env.Stderr, env.Stdin, common.NoColor)
	u.Header(target.Label + " — " + target.Path)

	if len(plan.Evict) == 0 {
		u.Success("Nothing to clean — every entry is already within policy.")
		return 0
	}

	u.KV("To remove", fmt.Sprintf("%d entries (%s)", len(plan.Evict), humanize.FormatSize(plan.EvictSize())))
	u.KV("To keep", fmt.Sprintf("%d entries (%s)", len(plan.Keep), humanize.FormatSize(sumSize(plan.Keep))))

	preview := plan.Evict
	const previewLimit = 10
	if len(preview) > previewLimit {
		preview = preview[:previewLimit]
	}
	now := time.Now()
	var rows [][]string
	for _, e := range preview {
		rows = append(rows, []string{u.Yellow(e.RelPath()), humanize.FormatSize(e.Size), humanize.FormatAge(now.Sub(e.ModTime))})
	}
	fmt.Fprintln(env.Stdout)
	u.Render(ui.Table{
		Columns: []ui.Column{{Header: "WILL REMOVE"}, {Header: "SIZE", Align: ui.AlignRight}, {Header: "AGE", Align: ui.AlignRight}},
	  Rows:    rows,
	})
	if len(plan.Evict) > len(preview) {
		u.Hint(fmt.Sprintf("...and %d more.", len(plan.Evict)-len(preview)))
	}

	if dryRun {
		u.Hint("Dry run: nothing was deleted. Re-run without --dry-run to apply.")
		return 0
	}

	if !yes {
		if !ui.IsInputInteractive() {
			u.Error("Refusing to delete without confirmation in a non-interactive session; pass --yes to proceed.")
			return 1
		}
		if !u.Confirm(fmt.Sprintf("Delete %d entries (%s) from %s? [y/N]", len(plan.Evict), humanize.FormatSize(plan.EvictSize()), target.Path)) {
			u.Warn("Aborted — nothing was deleted.")
			return 1
		}
	}

	purged := cache.Purge(plan.Evict)
	for _, f := range purged.Failed {
		u.Error(fmt.Sprintf("%s: %v", f.Entry.RelPath(), f.Err))
	}
	u.Success(fmt.Sprintf("Removed %d entries, freed %s", len(purged.Removed), humanize.FormatSize(purged.ReclaimedSize)))
	if len(purged.Failed) > 0 {
		u.Warn(fmt.Sprintf("%d entries could not be removed", len(purged.Failed)))
		return 1
	}
	return 0
}

func sumSize(entries []cache.Entry) int64 {
	var total int64
	for _, e := range entries {
		total += e.Size
	}
	return total
}
