const std = @import("std");

pub const Bucket = enum {
    manifests,
    outputs,
    zir,
    temp,
    packages,
    other,

    pub fn code(self: Bucket) []const u8 {
        return switch (self) {
            .manifests => "h",
            .outputs => "o",
            .zir => "z",
            .temp => "tmp",
            .packages => "p",
            .other => "?",
        };
    }

    pub fn fromCode(s: []const u8) Bucket {
        if (std.mem.eql(u8, s, "h")) return .manifests;
        if (std.mem.eql(u8, s, "o")) return .outputs;
        if (std.mem.eql(u8, s, "z")) return .zir;
        if (std.mem.eql(u8, s, "tmp")) return .temp;
        if (std.mem.eql(u8, s, "p")) return .packages;
        return .other;
    }

    pub fn purpose(self: Bucket) []const u8 {
        return switch (self) {
            .manifests => "Cache-hash manifests",
            .outputs => "Build output artifacts",
            .zir => "Incremental compilation (ZIR) cache",
            .temp => "Leftover temp dirs from interrupted runs",
            .packages => "Downloaded package tarballs",
            .other => "Unrecognized entry",
        };
    }
};

pub const Entry = struct {
    bucket: Bucket,
    name: []const u8,
    path: []const u8,
    size: i64,
    mod_time: i128,

    pub fn relPath(self: Entry, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.bucket.code(), self.name });
    }

    pub fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
    }
};

pub const BucketStats = struct {
    count: usize = 0,
    size: i64 = 0,
};

pub const Result = struct {
    root: []const u8,
    entries: []Entry,
    total_size: i64,
    by_bucket: std.AutoHashMapUnmanaged(Bucket, BucketStats),

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        for (self.entries) |e| e.deinit(allocator);
        allocator.free(self.entries);
        allocator.free(self.root);
        self.by_bucket.deinit(allocator);
    }
};

pub fn scan(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !Result {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var entries_list: std.ArrayList(Entry) = .empty;
    defer entries_list.deinit(allocator);

    var by_bucket: std.AutoHashMapUnmanaged(Bucket, BucketStats) = .empty;
    var total_size: i64 = 0;

    var it = dir.iterate();
    while (try it.next(io)) |item| {
        if (item.kind != .directory) continue;

        const bucket = Bucket.fromCode(item.name);
        var bucket_dir = dir.openDir(io, item.name, .{ .iterate = true }) catch continue;
        defer bucket_dir.close(io);

        var child_it = bucket_dir.iterate();
        while (try child_it.next(io)) |child| {
            const child_path = try std.fs.path.join(allocator, &[_][]const u8{ root, item.name, child.name });
            const measured = measure(io, child_path);

            const entry = Entry{
                .bucket = bucket,
                .name = try allocator.dupe(u8, child.name),
                .path = child_path,
                .size = measured.size,
                .mod_time = measured.mod_time,
            };
            try entries_list.append(allocator, entry);
            total_size += measured.size;

            const st = by_bucket.getPtr(bucket);
            if (st) |val| {
                val.count += 1;
                val.size += measured.size;
            } else {
                try by_bucket.put(allocator, bucket, BucketStats{ .count = 1, .size = measured.size });
            }
        }
    }

    const entries_slice = try entries_list.toOwnedSlice(allocator);
    std.sort.block(Entry, entries_slice, {}, sortEntrySizeDesc);

    return Result{
        .root = try allocator.dupe(u8, root),
        .entries = entries_slice,
        .total_size = total_size,
        .by_bucket = by_bucket,
    };
}

fn sortEntrySizeDesc(_: void, a: Entry, b: Entry) bool {
    return a.size > b.size;
}

pub fn measure(io: std.Io, path: []const u8) struct { size: i64, mod_time: i128 } {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return .{ .size = 0, .mod_time = 0 };
    if (stat.kind != .directory) {
        return .{ .size = @intCast(stat.size), .mod_time = stat.mtime.nanoseconds };
    }

    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return .{ .size = 0, .mod_time = stat.mtime.nanoseconds };
    defer dir.close(io);

    var size: i64 = 0;
    var mod_time: i128 = 0;
    var saw_file = false;

    var walker = dir.walk(std.heap.page_allocator) catch return .{ .size = 0, .mod_time = stat.mtime.nanoseconds };
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind == .file) {
            const file_stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
            saw_file = true;
            size += @intCast(file_stat.size);
            if (file_stat.mtime.nanoseconds > mod_time) {
                mod_time = file_stat.mtime.nanoseconds;
            }
        }
    }

    if (!saw_file) {
        mod_time = stat.mtime.nanoseconds;
    }
    return .{ .size = size, .mod_time = mod_time };
}
