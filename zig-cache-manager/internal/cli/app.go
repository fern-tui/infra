// Package cli implements zcm's command-line interface.
package cli

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"zig-cache-manager/internal/cache"
)

var Version = "0.0.045-beta.10"

// Env bundles I/O streams for a command invocation.
type Env struct {
	Args   []string
	Stdout io.Writer
	Stderr io.Writer
	Stdin  io.Reader
}

// Run parses args and dispatches to a subcommand.
// Returns 0 on success, 1 on runtime error, 2 on usage error.
func Run(env Env) int {
	args := env.Args

	if len(args) == 0 {
		return cmdInfo(nil, env)
	}

	switch args[0] {
	case "-h", "--help":
		printTopHelp(env.Stdout)
		return 0
	case "help":
		if len(args) > 1 {
			return printHelpFor(args[1], env.Stdout)
		}
		printTopHelp(env.Stdout)
		return 0
	case "-v", "--version", "version":
		fmt.Fprintf(env.Stdout, "%s\n", Version)
		return 0
	}

	cmd, rest := args[0], args[1:]
	// bare flags like -g or --max-size default to `info`.
	if strings.HasPrefix(cmd, "-") {
		cmd, rest = "info", args
	}

	switch cmd {
	case "info":
		return cmdInfo(rest, env)
	case "list", "ls":
		return cmdList(rest, env)
	case "clean":
		return cmdClean(rest, env)
	case "nuke":
		return cmdNuke(rest, env)
	default:
		fmt.Fprintf(env.Stderr, "zcm: unknown command %q\n\nRun 'zcm help' for usage.\n", cmd)
		return 2
	}
}

type CommonFlags struct {
	Global   bool
	CacheDir string
	NoColor  bool
	JSON     bool
}

func bindCommon(fs *flag.FlagSet, c *CommonFlags) {
	fs.BoolVar(&c.Global, "global", false, "target the global zig cache instead of the local .zig-cache")
	fs.BoolVar(&c.Global, "g", false, "shorthand for --global")
	fs.StringVar(&c.CacheDir, "cache-dir", "", "target this exact directory, skipping discovery")
	fs.BoolVar(&c.NoColor, "no-color", false, "disable colored output")
	fs.BoolVar(&c.JSON, "json", false, "print machine-readable JSON instead of a report")
}

// Target is the resolved cache directory and how it was found.
type Target struct {
	Path   string
	Label  string // "local cache", "global cache", or "cache directory" (--cache-dir)
	Source string // how the path was determined
}

// resolveTarget turns CommonFlags into a concrete, existing directory or a clear error.
func resolveTarget(c CommonFlags) (Target, error) {
	var t Target

	switch {
	case c.CacheDir != "":
		t = Target{Path: c.CacheDir, Label: "cache directory", Source: "--cache-dir"}
	case c.Global:
		dir, source, err := cache.Global()
		if err != nil {
			return Target{}, err
		}
		t = Target{Path: dir, Label: "global cache", Source: source}
	default:
		cwd, err := os.Getwd()
		if err != nil {
			return Target{}, err
		}
		dir, found, err := cache.Local(cwd)
		if err != nil {
			return Target{}, err
		}
		if !found {
			return Target{}, fmt.Errorf(
				"no .zig-cache found (searched upward from %s for build.zig)\n  "+
					"pass --cache-dir to target a specific directory, or --global for the shared cache", cwd)
		}
		t = Target{Path: dir, Label: "local cache", Source: "build.zig search"}
	}

	if abs, err := filepath.Abs(t.Path); err == nil {
		t.Path = abs
	}

	info, err := os.Stat(t.Path)
	if err != nil {
		if os.IsNotExist(err) {
			return Target{}, fmt.Errorf("%s not found at %s (it may not have been created yet)", t.Label, t.Path)
		}
		return Target{}, err
	}
	if !info.IsDir() {
		return Target{}, fmt.Errorf("%s is not a directory: %s", t.Label, t.Path)
	}
	return t, nil
}
