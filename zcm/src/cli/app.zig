const std = @import("std");
const cache = @import("../cache/discover.zig");
const cmd_info = @import("cmd_info.zig");
const cmd_list = @import("cmd_list.zig");
const cmd_clean = @import("cmd_clean.zig");
const cmd_nuke = @import("cmd_nuke.zig");
const help = @import("help.zig");

pub const version = "0.0.45-beta.10";

pub const Env = struct {
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    stdin: *std.Io.Reader,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,

    pub fn getenv(self: Env, key: []const u8) ?[]const u8 {
        return self.environ_map.get(key);
    }
};

pub fn run(allocator: std.mem.Allocator, env: Env) u8 {
    const args = env.args;
    if (args.len == 0) {
        return cmd_info.run(allocator, &[_][]const u8{}, env);
    }

    const first = args[0];
    if (std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
        help.printTopHelp(env.stdout);
        return 0;
    }
    if (std.mem.eql(u8, first, "help")) {
        if (args.len > 1) {
            return help.printHelpFor(args[1], env.stdout);
        }
        help.printTopHelp(env.stdout);
        return 0;
    }
    if (std.mem.eql(u8, first, "-v") or std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "version")) {
        env.stdout.print("{s}\n", .{version}) catch {};
        env.stdout.flush() catch {};
        return 0;
    }

    var cmd = first;
    var rest = args[1..];
    if (std.mem.startsWith(u8, cmd, "-")) {
        cmd = "info";
        rest = args;
    }

    if (std.mem.eql(u8, cmd, "info")) {
        return cmd_info.run(allocator, rest, env);
    } else if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "ls")) {
        return cmd_list.run(allocator, rest, env);
    } else if (std.mem.eql(u8, cmd, "clean")) {
        return cmd_clean.run(allocator, rest, env);
    } else if (std.mem.eql(u8, cmd, "nuke")) {
        return cmd_nuke.run(allocator, rest, env);
    } else {
        env.stderr.print("zcm: unknown command \"{s}\"\n\nRun 'zcm help' for usage.\n", .{cmd}) catch {};
        env.stderr.flush() catch {};
        return 2;
    }
}

pub const CommonFlags = struct {
    global: bool = false,
    cache_dir: ?[]const u8 = null,
    no_color: bool = false,
    json: bool = false,
};

pub const Target = struct {
    path: []const u8,
    label: []const u8,
    source: []const u8,

    pub fn deinit(self: Target, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub fn resolveTarget(allocator: std.mem.Allocator, env: Env, c: CommonFlags) !Target {
    var path: []const u8 = undefined;
    var label: []const u8 = undefined;
    var source: []const u8 = undefined;

    const EnvWrapper = struct {
        env_ref: Env,
        pub fn lookup(self: @This(), key: []const u8) ?[]const u8 {
            return self.env_ref.getenv(key);
        }
    };
    const wrapper = EnvWrapper{ .env_ref = env };

    if (c.cache_dir) |cd| {
        path = try allocator.dupe(u8, cd);
        label = "cache directory";
        source = "--cache-dir";
    } else if (c.global) {
        const glob = try cache.global(allocator, env.io, wrapper, EnvWrapper.lookup);
        path = glob.path;
        label = "global cache";
        source = glob.source;
    } else {
        const cwd = try std.process.currentPathAlloc(env.io, allocator);
        defer allocator.free(cwd);
        const loc = try cache.local(allocator, env.io, cwd, wrapper, EnvWrapper.lookup);
        if (!loc.found) {
            allocator.free(loc.path);
            return error.LocalCacheNotFound;
        }
        path = loc.path;
        label = "local cache";
        source = "build.zig search";
    }

    const stat = std.Io.Dir.cwd().statFile(env.io, path, .{}) catch |err| {
        if (err == error.FileNotFound) return error.CacheDirNotFound;
        return err;
    };
    if (stat.kind != .directory) return error.CacheNotADirectory;

    return Target{
        .path = path,
        .label = label,
        .source = source,
    };
}
