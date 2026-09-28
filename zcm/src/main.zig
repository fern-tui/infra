const std = @import("std");
const cli = @import("cli/app.zig");

// Export tests from submodules for `zig test`
test {
    _ = @import("humanize/size.zig");
    _ = @import("humanize/duration.zig");
    _ = @import("cache/discover.zig");
    _ = @import("cache/policy.zig");
    _ = @import("cache/scan.zig");
    _ = @import("cache/purge.zig");
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout: *std.Io.Writer = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr: *std.Io.Writer = &stderr_writer.interface;

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const stdin: *std.Io.Reader = &stdin_reader.interface;

    defer {
        stdout.flush() catch {};
        stderr.flush() catch {};
    }

    const exit_code = cli.run(gpa, cli.Env{
        .args = if (args.len > 1) args[1..] else &[_][]const u8{},
        .stdout = stdout,
        .stderr = stderr,
        .stdin = stdin,
        .io = io,
        .environ_map = init.environ_map,
    });

    std.process.exit(exit_code);
}
