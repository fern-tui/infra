const std = @import("std");
const Entry = @import("scan.zig").Entry;

pub const FailedEntry = struct {
    entry: Entry,
    err_msg: []const u8,
};

pub const PurgeResult = struct {
    removed: std.ArrayList(Entry),
    failed: std.ArrayList(FailedEntry),
    reclaimed_size: i64,

    pub fn deinit(self: *PurgeResult, allocator: std.mem.Allocator) void {
        self.removed.deinit(allocator);
        for (self.failed.items) |f| {
            allocator.free(f.err_msg);
        }
        self.failed.deinit(allocator);
    }
};

pub fn purge(allocator: std.mem.Allocator, io: std.Io, entries: []const Entry) PurgeResult {
    var removed: std.ArrayList(Entry) = .empty;
    var failed: std.ArrayList(FailedEntry) = .empty;
    var reclaimed_size: i64 = 0;

    for (entries) |e| {
        deletePath(io, e.path) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}) catch "error";
            failed.append(allocator, .{ .entry = e, .err_msg = msg }) catch {};
            continue;
        };
        removed.append(allocator, e) catch {};
        reclaimed_size += e.size;
    }

    return PurgeResult{
        .removed = removed,
        .failed = failed,
        .reclaimed_size = reclaimed_size,
    };
}

fn deletePath(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().deleteTree(io, path);
}

pub fn nuke(io: std.Io, path: []const u8, home_dir: ?[]const u8) !void {
    try checkSafeToDelete(path, home_dir);
    try deletePath(io, path);
}

pub fn checkSafeToDelete(path: []const u8, home_dir: ?[]const u8) !void {
    const parent = std.fs.path.dirname(path);
    if (parent == null or std.mem.eql(u8, parent.?, path)) {
        return error.RefusingRootPath;
    }

    if (home_dir) |home| {
        if (std.mem.eql(u8, path, home)) return error.RefusingHomeDirectory;
    }

    const base = std.fs.path.basename(path);
    var base_lower_buf: [128]u8 = undefined;
    const base_lower = std.ascii.lowerString(&base_lower_buf, base);

    const looks_like_cache = std.mem.eql(u8, base_lower, "zig") or
        std.mem.eql(u8, base_lower, ".zig-cache") or
        std.mem.eql(u8, base_lower, "zig-cache") or
        std.mem.containsAtLeast(u8, base_lower, 1, "zig-cache");

    var depth: usize = 0;
    for (path) |c| {
        if (c == '/' or c == '\\') depth += 1;
    }

    if (!looks_like_cache and depth <= 2) {
        return error.UnsafeCachePath;
    }
}
