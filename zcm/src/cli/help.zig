const std = @import("std");

pub const top_help =
    \\zcm — a cache manager for the Zig compiler's build cache
    \\
    \\USAGE
    \\  zcm [command] [flags]
    \\
    \\COMMANDS
    \\  info     Show a summary of the cache (default when no command is given)
    \\  list     List individual cache entries by size and age
    \\  clean    Evict entries by age, size, or count policy
    \\  nuke     Delete an entire cache directory
    \\  version  Print the zcm version
    \\  help     Show this help, or 'zcm help <command>' for command help
    \\
    \\GLOBAL FLAGS
    \\  -g, --global         Target the global zig cache instead of the local .zig-cache
    \\      --cache-dir DIR  Target an exact directory, skipping discovery
    \\      --no-color       Disable colored output
    \\      --json           Print machine-readable JSON instead of a report
    \\
    \\EXAMPLES
    \\  zcm                              Summarize the local cache
    \\  zcm list --sort age              List entries, oldest first
    \\  zcm clean --older-than 14d -n    Preview removing anything untouched for 2 weeks
    \\  zcm clean --max-size 2G --yes    Trim the cache down to 2 GB, no prompt
    \\  zcm nuke --global --yes          Wipe the global cache entirely
    \\
    \\Run 'zcm help <command>' for details on a specific command.
    \\
;

pub const info_help =
    \\zcm info — show a summary of a cache directory
    \\
    \\USAGE
    \\  zcm info [flags]
    \\
    \\Shows the total size and entry count, plus a breakdown by bucket (h, o, z,
    \\tmp, p) with a one-line description of what each bucket holds.
    \\
    \\FLAGS
    \\  -g, --global         Target the global zig cache instead of the local .zig-cache
    \\      --cache-dir DIR  Target an exact directory, skipping discovery
    \\      --no-color       Disable colored output
    \\      --json           Print machine-readable JSON instead of a report
    \\
    \\EXAMPLES
    \\  zcm info
    \\  zcm info --global
    \\  zcm info --cache-dir /tmp/some-project/.zig-cache --json
    \\
;

pub const list_help =
    \\zcm list — list individual cache entries
    \\
    \\USAGE
    \\  zcm list [flags]
    \\
    \\Lists each entry (one per bucket sub-folder, e.g. "o/c6ee5a...") with its
    \\size and age. Age is time since the entry was last written — zig does not
    \\update an entry's timestamp on a cache hit, only on creation, so an old age
    \\means "unchanged since then", not "unused since then".
    \\
    \\FLAGS
    \\  -g, --global         Target the global zig cache instead of the local .zig-cache
    \\      --cache-dir DIR  Target an exact directory, skipping discovery
    \\      --no-color       Disable colored output
    \\      --json           Print machine-readable JSON instead of a report
    \\      --sort STRING    Sort by: size, age, name (default "size")
    \\      --asc            Sort ascending instead of descending
    \\      --bucket STRING  Only show entries from this bucket (h, o, z, tmp, p)
    \\      --limit N        Max entries to show, 0 for no limit (default 30)
    \\
    \\EXAMPLES
    \\  zcm list --sort age --asc
    \\  zcm list --bucket tmp
    \\  zcm list --global --limit 0
    \\
;

pub const clean_help =
    \\zcm clean — evict entries by age, size, or count policy
    \\
    \\USAGE
    \\  zcm clean (--older-than DURATION | --max-size SIZE | --max-count N) [flags]
    \\
    \\At least one of --older-than, --max-size, or --max-count is required.
    \\Entries violating --older-than are always evicted; --max-size and
    \\--max-count then remove additional oldest-first entries only if still
    \\needed to satisfy the cap.
    \\
    \\Without --yes, you'll be asked to confirm before anything is deleted. In a
    \\non-interactive session (no terminal attached to stdin), --yes is required.
    \\
    \\FLAGS
    \\  -g, --global         Target the global zig cache instead of the local .zig-cache
    \\      --cache-dir DIR  Target an exact directory, skipping discovery
    \\      --no-color       Disable colored output
    \\      --json           Print machine-readable JSON instead of a report
    \\      --older-than D   Evict entries last written before this long ago (7d, 24h, 2w)
    \\      --max-size S     Evict oldest entries until the cache is under this size (5G, 500M)
    \\      --max-count N    Evict oldest entries until at most N remain
    \\      --bucket STRING  Only consider entries from this bucket (h, o, z, tmp, p)
    \\  -n, --dry-run        Show what would be removed without deleting anything
    \\  -y, --yes            Don't prompt for confirmation
    \\
    \\EXAMPLES
    \\  zcm clean --older-than 14d --dry-run
    \\  zcm clean --max-size 5G --yes
    \\  zcm clean --bucket tmp --older-than 0s --yes   # sweep all leftover tmp dirs
    \\
;

pub const nuke_help =
    \\zcm nuke — delete an entire cache directory
    \\
    \\USAGE
    \\  zcm nuke [flags]
    \\
    \\Deletes the whole target directory, not just selected entries. zig will
    \\recreate it automatically the next time it needs to. Refuses to run
    \\against a path that doesn't look like a zig cache directory.
    \\
    \\Without --yes, you'll be asked to confirm before anything is deleted. In a
    \\non-interactive session (no terminal attached to stdin), --yes is required.
    \\
    \\FLAGS
    \\  -g, --global         Target the global zig cache instead of the local .zig-cache
    \\      --cache-dir DIR  Target an exact directory, skipping discovery
    \\      --no-color       Disable colored output
    \\  -n, --dry-run        Show what would be deleted without deleting anything
    \\  -y, --yes            Don't prompt for confirmation
    \\
    \\EXAMPLES
    \\  zcm nuke --dry-run
    \\  zcm nuke --global --yes
    \\
;

pub fn printTopHelp(writer: *std.Io.Writer) void {
    writer.print("{s}", .{top_help}) catch {};
    writer.flush() catch {};
}

pub fn printHelpFor(name: []const u8, writer: *std.Io.Writer) u8 {
    if (std.mem.eql(u8, name, "info")) {
        writer.print("{s}", .{info_help}) catch {};
    } else if (std.mem.eql(u8, name, "list") or std.mem.eql(u8, name, "ls")) {
        writer.print("{s}", .{list_help}) catch {};
    } else if (std.mem.eql(u8, name, "clean")) {
        writer.print("{s}", .{clean_help}) catch {};
    } else if (std.mem.eql(u8, name, "nuke")) {
        writer.print("{s}", .{nuke_help}) catch {};
    } else if (std.mem.eql(u8, name, "version")) {
        writer.print("zcm version — print the zcm version\n\nUSAGE\n  zcm version\n", .{}) catch {};
    } else {
        writer.print("zcm: no help for unknown command \"{s}\"\n\n", .{name}) catch {};
        printTopHelp(writer);
        return 2;
    }
    writer.flush() catch {};
    return 0;
}
