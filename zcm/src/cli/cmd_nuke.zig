const std = @import("std");
const app = @import("app.zig");
const scan_mod = @import("../cache/scan.zig");
const purge_mod = @import("../cache/purge.zig");
const humanize_size = @import("../humanize/size.zig");
const ui_mod = @import("../ui/ui.zig");
const help_mod = @import("help.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8, env: app.Env) u8 {
    var common = app.CommonFlags{};
    var dry_run: bool = false;
    var yes: bool = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--global")) {
            common.global = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            common.no_color = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "-y") or std.mem.eql(u8, arg, "--yes")) {
            yes = true;
        } else if (std.mem.eql(u8, arg, "--cache-dir") and i + 1 < args.len) {
            i += 1;
            common.cache_dir = args[i];
        } else if (std.mem.startsWith(u8, arg, "--cache-dir=")) {
            common.cache_dir = arg["--cache-dir=".len..];
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            _ = help_mod.printHelpFor("nuke", env.stdout);
            return 0;
        }
    }

    const target = app.resolveTarget(allocator, env, common) catch |err| {
        env.stderr.print("zcm: {s}\n", .{@errorName(err)}) catch {};
        env.stderr.flush() catch {};
        return 1;
    };
    defer target.deinit(allocator);

    var res_opt = scan_mod.scan(allocator, env.io, target.path) catch null;
    defer if (res_opt) |*r| r.deinit(allocator);

    const no_color = common.no_color or (env.getenv("NO_COLOR") != null and env.getenv("NO_COLOR").?.len > 0);
    const ui = ui_mod.UI.init(env.stdout, env.stderr, env.stdin, no_color);
    var head_buf: [256]u8 = undefined;
    const header_str = std.fmt.bufPrint(&head_buf, "{s} — {s}", .{ target.label, target.path }) catch target.path;
    ui.header(header_str);

    if (res_opt) |r| {
        var delete_buf: [128]u8 = undefined;
        const delete_msg = std.fmt.bufPrint(&delete_buf, "the entire directory: {d} entries, {s}", .{
            r.entries.len,
            humanize_size.formatSize(r.total_size).slice(),
        }) catch "the entire directory";
        ui.kv("Will delete", delete_msg);
    } else {
        ui.kv("Will delete", "the entire directory (could not pre-scan its contents)");
    }

    if (dry_run) {
        ui.hint("Dry run: nothing was deleted.");
        return 0;
    }

    if (!yes) {
        if (!ui_mod.UI.isInputInteractive()) {
            ui.err("Refusing to delete without confirmation in a non-interactive session; pass --yes to proceed.");
            return 1;
        }
        var confirm_buf: [256]u8 = undefined;
        const prompt = std.fmt.bufPrint(&confirm_buf, "Permanently delete the entire {s} at {s}? [y/N]", .{
            target.label,
            target.path,
        }) catch "Confirm nuke? [y/N]";

        if (!ui.confirm(prompt)) {
            ui.warn("Aborted — nothing was deleted.");
            return 1;
        }
    }

    const home_dir = env.getenv("HOME");
    purge_mod.nuke(env.io, target.path, home_dir) catch |err| {
        var err_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&err_buf, "failed to delete: {s}", .{@errorName(err)}) catch "delete error";
        ui.err(msg);
        return 1;
    };

    var succ_buf: [256]u8 = undefined;
    const succ_msg = std.fmt.bufPrint(&succ_buf, "Deleted {s}", .{target.path}) catch "Deleted cache";
    ui.success(succ_msg);
    return 0;
}
