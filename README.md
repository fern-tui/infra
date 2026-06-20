>[!NOTE]
>This toolchain is built specifically for the fern-tui team's internal use and is not intended for the `general public`.
>Please use it with caution. It is intentionally `minimal` and not under `active` development. Bug reports are welcome, but updates may be infrequent.

# zig-cache-manager (`zcm`)

A fast, zero-dependency CLI tool for inspecting and pruning the Zig compiler's build cache.

## Why

`zig build` stores artifacts in `.zig-cache/` (local, per-project) and `~/.cache/zig` (global, shared across projects). These directories grow unbounded until you nuke them manually — and `rm -rf .zig-cache` is destructive if your project is still building. `zcm` gives you fine-grained control: preview before you delete, evict by age or size cap, or wipe surgically.

```bash
❯ zcm help
zcm — a cache manager for the Zig compiler's build cache

USAGE
  zcm [command] [flags]

COMMANDS
  info     Show a summary of the cache (default when no command is given)
  list     List individual cache entries by size and age
  clean    Evict entries by age, size, or count policy
  nuke     Delete an entire cache directory
  version  Print the zcm version
  help     Show this help, or 'zcm help <command>' for command help

GLOBAL FLAGS
  -g, --global         Target the global zig cache instead of the local .zig-cache
      --cache-dir DIR  Target an exact directory, skipping discovery
      --no-color       Disable colored output
      --json           Print machine-readable JSON instead of a report

EXAMPLES
  zcm                              Summarize the local cache
  zcm list --sort age              List entries, oldest first
  zcm clean --older-than 14d -n    Preview removing anything untouched for 2 weeks
  zcm clean --max-size 2G --yes    Trim the cache down to 2 GB, no prompt
  zcm nuke --global --yes          Wipe the global cache entirely

Run 'zcm help <command>' for details on a specific command.
```
