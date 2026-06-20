package cli

import (
	"flag"
	"fmt"
	"sort"
	"strings"
	"time"

	"zig-cache-manager/internal/cache"
	"zig-cache-manager/internal/humanize"
	"zig-cache-manager/internal/ui"
)

type entryJSON struct {
	Entry     string `json:"entry"`
	Bucket    string `json:"bucket"`
	SizeBytes int64  `json:"size_bytes"`
	AgeSeconds int64 `json:"age_seconds"`
	ModifiedAt string `json:"modified_at"`
}

func cmdList(args []string, env Env) int {
	var common CommonFlags
	var sortBy, bucketFilter string
	var limit int
	var ascending bool

	fs := flag.NewFlagSet("list", flag.ExitOnError)
	fs.SetOutput(env.Stderr)
	bindCommon(fs, &common)
	fs.StringVar(&sortBy, "sort", "size", "sort by: size, age, name")
	fs.StringVar(&bucketFilter, "bucket", "", "only show entries from this bucket (h, o, z, tmp, p)")
	fs.IntVar(&limit, "limit", 30, "max entries to show (0 = no limit)")
	fs.BoolVar(&ascending, "asc", false, "sort ascending instead of descending")
	fs.Usage = func() { printHelpFor("list", env.Stdout) }
	fs.Parse(args)

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

	entries := result.Entries
	if bucketFilter != "" {
		filtered := make([]cache.Entry, 0, len(entries))
		for _, e := range entries {
			if string(e.Bucket) == bucketFilter {
				filtered = append(filtered, e)
			}
		}
		entries = filtered
	}

	switch sortBy {
		case "size":
			sort.Slice(entries, func(i, j int) bool { return entries[i].Size > entries[j].Size })
		case "age":
			sort.Slice(entries, func(i, j int) bool { return entries[i].ModTime.Before(entries[j].ModTime) })
		case "name":
			sort.Slice(entries, func(i, j int) bool { return entries[i].RelPath() < entries[j].RelPath() })
		default:
			fmt.Fprintf(env.Stderr, "zcm: unknown --sort value %q (want size, age, or name)\n", sortBy)
			return 2
	}
	if ascending {
		for i, j := 0, len(entries)-1; i < j; i, j = i+1, j-1 {
			entries[i], entries[j] = entries[j], entries[i]
		}
	}

	total := len(entries)
	shown := entries
	if limit > 0 && len(shown) > limit {
		shown = shown[:limit]
	}

	if common.JSON {
		out := make([]entryJSON, len(shown))
		now := time.Now()
		for i, e := range shown {
			out[i] = entryJSON{
				Entry:      e.RelPath(),
				Bucket:     string(e.Bucket),
				SizeBytes:  e.Size,
				AgeSeconds: int64(now.Sub(e.ModTime).Seconds()),
				ModifiedAt: e.ModTime.Format(time.RFC3339),
			}
		}
		return printJSON(env.Stdout, out)
	}

	u := ui.New(env.Stdout, env.Stderr, env.Stdin, common.NoColor)
	u.CacheHeader(target.Label, target.Path, len(result.Entries), humanize.FormatSize(result.TotalSize))

	if len(shown) == 0 {
		u.Hint("No entries match.")
		return 0
	}

	now := time.Now()
	var rows [][]string
	var shownSize int64
	for _, e := range shown {
		age := now.Sub(e.ModTime)
		shownSize += e.Size
		// Entries with a file extension (e.g. h/ manifests "abc.txt") are
		// secondary metadata — dim the whole row so they recede visually.
		if strings.ContainsRune(e.Name, '.') {
			rows = append(rows, []string{
				u.Dim(e.RelPath()),
				      u.Dim(humanize.FormatSize(e.Size)),
				      u.Dim(humanize.FormatAge(age)),
			})
		} else {
			rows = append(rows, []string{
				u.EntryPath(string(e.Bucket), e.Name),
				      u.AgeColor(humanize.FormatSize(e.Size), age),
				      u.AgeColor(humanize.FormatAge(age), age),
			})
		}
	}
	rows = append(rows, []string{
		u.Gray(fmt.Sprintf("%d of %d entries", len(shown), total)),
		      u.Gray(humanize.FormatSize(shownSize)),
		      "",
	})

	fmt.Fprintln(env.Stdout)
	u.Render(ui.Table{
		Columns: []ui.Column{
			{Header: "ENTRY"},
			{Header: "SIZE", Align: ui.AlignRight},
			{Header: "AGE", Align: ui.AlignRight},
		},
	  Rows:     rows,
	  FootRule: true,
	})

	if limit > 0 && total > limit {
		u.Hint(fmt.Sprintf("Showing %d of %d entries — pass --limit 0 to see all.", limit, total))
	}
	return 0
}
