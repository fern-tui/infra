package cli

import (
	"flag"
	"fmt"

	"zig-cache-manager/internal/cache"
	"zig-cache-manager/internal/humanize"
	"zig-cache-manager/internal/ui"
)

func cmdNuke(args []string, env Env) int {
	var common CommonFlags
	var dryRun, yes bool

	fs := flag.NewFlagSet("nuke", flag.ExitOnError)
	fs.SetOutput(env.Stderr)
	bindCommon(fs, &common)
	fs.BoolVar(&dryRun, "dry-run", false, "show what would be deleted without deleting anything")
	fs.BoolVar(&dryRun, "n", false, "shorthand for --dry-run")
	fs.BoolVar(&yes, "yes", false, "don't prompt for confirmation")
	fs.BoolVar(&yes, "y", false, "shorthand for --yes")
	fs.Usage = func() { printHelpFor("nuke", env.Stdout) }
	fs.Parse(args)

	target, err := resolveTarget(common)
	if err != nil {
		fmt.Fprintf(env.Stderr, "zcm: %v\n", err)
		return 1
	}

	// Best-effort: still proceed even if the scan itself fails (e.g. a
	// permission-denied subdirectory), since nuke doesn't need per-entry
	// detail, only the target path.
	result, _ := cache.Scan(target.Path)

	u := ui.New(env.Stdout, env.Stderr, env.Stdin, common.NoColor)
	u.Header(target.Label + " — " + target.Path)
	if result != nil {
		u.KV("Will delete", fmt.Sprintf("the entire directory: %d entries, %s", len(result.Entries), humanize.FormatSize(result.TotalSize)))
	} else {
		u.KV("Will delete", "the entire directory (could not pre-scan its contents)")
	}

	if dryRun {
		u.Hint("Dry run: nothing was deleted.")
		return 0
	}

	if !yes {
		if !ui.IsInputInteractive() {
			u.Error("Refusing to delete without confirmation in a non-interactive session; pass --yes to proceed.")
			return 1
		}
		if !u.Confirm(fmt.Sprintf("Permanently delete the entire %s at %s? [y/N]", target.Label, target.Path)) {
			u.Warn("Aborted — nothing was deleted.")
			return 1
		}
	}

	if err := cache.Nuke(target.Path); err != nil {
		u.Error(err.Error())
		return 1
	}
	u.Success("Deleted " + target.Path)
	return 0
}
