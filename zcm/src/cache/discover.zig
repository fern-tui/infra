const std = @import("std");
const builtin = @import("builtin");

pub const TargetResult = struct {
    path: []const u8,
    source: []const u8,
};

pub fn global(
    allocator: std.mem.Allocator,
    io: std.Io,
    ctx: anytype,
    lookup: fn (@TypeOf(ctx), []const u8) ?[]const u8,
) !TargetResult {
    if (globalFromZigEnv(allocator, io)) |dir| {
        return TargetResult{ .path = dir, .source = "zig env" };
    }
    return globalFallback(allocator, builtin.os.tag, ctx, lookup);
}

pub fn globalFromZigEnv(allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
    var proc = std.process.spawn(io, .{
        .argv = &[_][]const u8{ "zig", "env" },
        .stdout = .pipe,
    }) catch return null;
    defer _ = proc.wait(io) catch {};

    var buf: [4096]u8 = undefined;
    var r = proc.stdout.?.reader(io, &buf);
    const stdout_data = r.interface.readAlloc(allocator, 1024 * 1024) catch return null;
    defer allocator.free(stdout_data);

    return zonStringField(stdout_data, "global_cache_dir", allocator) catch null;
}

pub fn globalFallback(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    ctx: anytype,
    lookup: fn (@TypeOf(ctx), []const u8) ?[]const u8,
) !TargetResult {
    if (lookup(ctx, "ZIG_GLOBAL_CACHE_DIR")) |v| {
        if (v.len > 0) return TargetResult{ .path = try allocator.dupe(u8, v), .source = "ZIG_GLOBAL_CACHE_DIR" };
    }

    if (os_tag == .windows) {
        if (lookup(ctx, "LOCALAPPDATA")) |v| {
            if (v.len > 0) {
                const trimmed = std.mem.trimEnd(u8, v, "\\/");
                const path = try std.fmt.allocPrint(allocator, "{s}\\zig", .{trimmed});
                return TargetResult{ .path = path, .source = "%LOCALAPPDATA%\\zig" };
            }
        }
        return error.LocalappdataNotSet;
    }

    if (lookup(ctx, "XDG_CACHE_HOME")) |v| {
        if (v.len > 0) {
            const trimmed = std.mem.trimEnd(u8, v, "/");
            const path = try std.fmt.allocPrint(allocator, "{s}/zig", .{trimmed});
            return TargetResult{ .path = path, .source = "$XDG_CACHE_HOME/zig" };
        }
    }

    if (lookup(ctx, "HOME")) |v| {
        if (v.len > 0) {
            const trimmed = std.mem.trimEnd(u8, v, "/");
            const path = try std.fmt.allocPrint(allocator, "{s}/.cache/zig", .{trimmed});
            return TargetResult{ .path = path, .source = "$HOME/.cache/zig" };
        }
    }

    return error.NoCacheHomeSet;
}

pub fn local(
    allocator: std.mem.Allocator,
    io: std.Io,
    start_dir: []const u8,
    ctx: anytype,
    lookup: fn (@TypeOf(ctx), []const u8) ?[]const u8,
) !struct { path: []const u8, found: bool } {
    if (lookup(ctx, "ZIG_LOCAL_CACHE_DIR")) |override| {
        if (override.len > 0) {
            const stat = std.Io.Dir.cwd().statFile(io, override, .{}) catch return .{ .path = try allocator.dupe(u8, override), .found = false };
            return .{ .path = try allocator.dupe(u8, override), .found = (stat.kind == .directory) };
        }
    }

    var base = start_dir;
    const root_opt = findBuildRoot(allocator, io, start_dir);
    if (root_opt) |r| {
        base = r;
    }
    defer if (root_opt) |r| allocator.free(r);

    const candidate = try std.fs.path.join(allocator, &[_][]const u8{ base, ".zig-cache" });
    const stat = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch return .{ .path = candidate, .found = false };
    return .{ .path = candidate, .found = (stat.kind == .directory) };
}

pub fn findBuildRoot(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) ?[]const u8 {
    var current = allocator.dupe(u8, dir) catch return null;
    while (true) {
        const build_zig_path = std.fs.path.join(allocator, &[_][]const u8{ current, "build.zig" }) catch {
            allocator.free(current);
            return null;
        };
        defer allocator.free(build_zig_path);

        if (std.Io.Dir.cwd().statFile(io, build_zig_path, .{})) |stat| {
            if (stat.kind != .directory) return current;
        } else |_| {}

        const parent = std.fs.path.dirname(current);
        if (parent == null or std.mem.eql(u8, parent.?, current)) {
            allocator.free(current);
            return null;
        }

        const next = allocator.dupe(u8, parent.?) catch {
            allocator.free(current);
            return null;
        };
        allocator.free(current);
        current = next;
    }
}

pub fn zonStringField(data: []const u8, field: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    var line_it = std.mem.splitScalar(u8, data, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, ".")) continue;
        const without_dot = line[1..];
        if (!std.mem.startsWith(u8, without_dot, field)) continue;

        const tail = without_dot[field.len..];
        if (tail.len > 0 and tail[0] != ' ' and tail[0] != '=') continue;

        var rest = std.mem.trimStart(u8, tail, " =");
        const first = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        const last = std.mem.lastIndexOfScalar(u8, rest, '"') orelse continue;
        if (last <= first) continue;

        return try unescapeZonString(allocator, rest[first + 1 .. last]);
    }
    return null;
}

fn unescapeZonString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (!std.mem.containsAtLeast(u8, s, 1, "\\")) {
        return allocator.dupe(u8, s);
    }
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            switch (s[i]) {
                'n' => try list.append(allocator, '\n'),
                't' => try list.append(allocator, '\t'),
                'r' => try list.append(allocator, '\r'),
                '"' => try list.append(allocator, '"'),
                '\\' => try list.append(allocator, '\\'),
                else => {
                    try list.append(allocator, '\\');
                    try list.append(allocator, s[i]);
                },
            }
            i += 1;
            continue;
        }
        try list.append(allocator, s[i]);
        i += 1;
    }
    return list.toOwnedSlice(allocator);
}

test "globalFallback precedence" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const DummyEnv = struct {
        pub fn lookup(_: @This(), k: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, k, "ZIG_GLOBAL_CACHE_DIR")) return "/custom/cache";
            if (std.mem.eql(u8, k, "HOME")) return "/home/x";
            return null;
        }
        pub fn lookupWin(_: @This(), k: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, k, "LOCALAPPDATA")) return "C:\\Users\\x\\AppData\\Local";
            return null;
        }
        pub fn lookupLinuxXdg(_: @This(), k: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, k, "XDG_CACHE_HOME")) return "/xdg";
            if (std.mem.eql(u8, k, "HOME")) return "/home/x";
            return null;
        }
        pub fn lookupDarwinHome(_: @This(), k: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, k, "HOME")) return "/Users/x";
            return null;
        }
        pub fn lookupEmpty(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    };

    const dummy = DummyEnv{};
    {
        const res = try globalFallback(allocator, .linux, dummy, DummyEnv.lookup);
        defer allocator.free(res.path);
        try testing.expectEqualStrings("/custom/cache", res.path);
        try testing.expectEqualStrings("ZIG_GLOBAL_CACHE_DIR", res.source);
    }
    {
        const res = try globalFallback(allocator, .windows, dummy, DummyEnv.lookupWin);
        defer allocator.free(res.path);
        try testing.expectEqualStrings("C:\\Users\\x\\AppData\\Local\\zig", res.path);
        try testing.expectEqualStrings("%LOCALAPPDATA%\\zig", res.source);
    }
    {
        const res = try globalFallback(allocator, .linux, dummy, DummyEnv.lookupLinuxXdg);
        defer allocator.free(res.path);
        try testing.expectEqualStrings("/xdg/zig", res.path);
        try testing.expectEqualStrings("$XDG_CACHE_HOME/zig", res.source);
    }
    {
        const res = try globalFallback(allocator, .macos, dummy, DummyEnv.lookupDarwinHome);
        defer allocator.free(res.path);
        try testing.expectEqualStrings("/Users/x/.cache/zig", res.path);
        try testing.expectEqualStrings("$HOME/.cache/zig", res.source);
    }
    {
        try testing.expectError(error.NoCacheHomeSet, globalFallback(allocator, .linux, dummy, DummyEnv.lookupEmpty));
        try testing.expectError(error.LocalappdataNotSet, globalFallback(allocator, .windows, dummy, DummyEnv.lookupEmpty));
    }
}
