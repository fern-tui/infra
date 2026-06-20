package cli

import (
	"flag"
	"fmt"
	"sort"
	"strconv"

	"zig-cache-manager/internal/cache"
	"zig-cache-manager/internal/humanize"
	"zig-cache-manager/internal/ui"
)

type bucketJSON struct {
	Count     int   `json:"count"`
	SizeBytes int64 `json:"size_bytes"`
	Purpose   string `json:"purpose"`
}

type infoJSON struct {
	Path           string                `json:"path"`
	Kind           string                `json:"kind"`
	ResolvedVia    string                `json:"resolved_via"`
	Entries        int                   `json:"entries"`
	TotalSizeBytes int64                 `json:"total_size_bytes"`
	Buckets        map[string]bucketJSON `json:"buckets"`
}

func cmdInfo(args []string, env Env) int {
	var common CommonFlags
	fs := flag.NewFlagSet("info", flag.ExitOnError)
	fs.SetOutput(env.Stderr)
	bindCommon(fs, &common)
	fs.Usage = func() { printHelpFor("info", env.Stdout) }
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

	if common.JSON {
		buckets := map[string]bucketJSON{}
		for b, stats := range result.ByBucket {
			buckets[string(b)] = bucketJSON{Count: stats.Count, SizeBytes: stats.Size, Purpose: b.Purpose()}
		}
		return printJSON(env.Stdout, infoJSON{
			Path:           target.Path,
			Kind:           target.Label,
			ResolvedVia:    target.Source,
			Entries:        len(result.Entries),
			TotalSizeBytes: result.TotalSize,
			Buckets:        buckets,
		})
	}

	u := ui.New(env.Stdout, env.Stderr, env.Stdin, common.NoColor)
	u.Header(target.Label + " — " + target.Path)
	u.KV("Entries", strconv.Itoa(len(result.Entries)))
	u.KV("Total size", humanize.FormatSize(result.TotalSize))

	if len(result.ByBucket) > 0 {
		var buckets []cache.Bucket
		for b := range result.ByBucket {
			buckets = append(buckets, b)
		}
		sort.Slice(buckets, func(i, j int) bool {
			return result.ByBucket[buckets[i]].Size > result.ByBucket[buckets[j]].Size
		})

		var rows [][]string
		for _, b := range buckets {
			st := result.ByBucket[b]
			rows = append(rows, []string{
				string(b),
				strconv.Itoa(st.Count),
				humanize.FormatSize(st.Size),
				b.Purpose(),
			})
		}
		fmt.Fprintln(env.Stdout)
		u.Render(ui.Table{
			Columns: []ui.Column{
				{Header: "BUCKET"},
				{Header: "ENTRIES", Align: ui.AlignRight},
				{Header: "SIZE", Align: ui.AlignRight},
				{Header: "PURPOSE"},
			},
			Rows: rows,
		})
	}

	u.Hint("Run 'zcm list' to see individual entries, or 'zcm clean --help' to free up space.")
	return 0
}
