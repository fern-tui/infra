const std = @import("std");
const app = @import("app.zig");
const scan_mod = @import("../cache/scan.zig");
const policy_mod = @import("../cache/policy.zig");
const purge_mod = @import("../cache/purge.zig");
const humanize_size = @import("../humanize/size.zig");
const humanize_dur = @import("../humanize/duration.zig");
const ui_mod = @import("../ui/ui.zig");
const json_mod = @import("json.zig");
const help_mod = @import("help.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8, env: app.Env) u8 {
    var common = app.CommonFlags{};
    var older_than_str: ?[]const u8 = null;
    var max_size_str: ?[]const u8 = null;
    var max_count: usize = 0;
    var bucket_filter: ?[]const u8 = null;
    var dry_run: bool = false;
    var yes: bool = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--global")) {
            common.global = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            common.no_color = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            common.json = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "-y") or std.mem.eql(u8, arg, "--yes")) {
            yes = true;
        } else if (std.mem.eql(u8, arg, "--older-than") and i + 1 < args.len) {
            i += 1;
            older_than_str = args[i];
        } else if (std.mem.startsWith(u8, arg, "--older-than=")) {
            older_than_str = arg["--older-than=".len..];
        } else if (std.mem.eql(u8, arg, "--max-size") and i + 1 < args.len) {
            i += 1;
            max_size_str = args[i];
        } else if (std.mem.startsWith(u8, arg, "--max-size=")) {
            max_size_str = arg["--max-size=".len..];
        } else if (std.mem.eql(u8, arg, "--max-count") and i + 1 < args.len) {
            i += 1;
            max_count = std.fmt.parseInt(usize, args[i], 10) catch 0;
        } else if (std.mem.startsWith(u8, arg, "--max-count=")) {
            max_count = std.fmt.parseInt(usize, arg["--max-count=".len..], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--bucket") and i + 1 < args.len) {
            i += 1;
            bucket_filter = args[i];
        } else if (std.mem.startsWith(u8, arg, "--bucket=")) {
            bucket_filter = arg["--bucket=".len..];
        } else if (std.mem.eql(u8, arg, "--cache-dir") and i + 1 < args.len) {
            i += 1;
            common.cache_dir = args[i];
        } else if (std.mem.startsWith(u8, arg, "--cache-dir=")) {
            common.cache_dir = arg["--cache-dir=".len..];
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            _ = help_mod.printHelpFor("clean", env.stdout);
            return 0;
        }
    }

    if (older_than_str == null and max_size_str == null and max_count == 0) {
        env.stderr.print("zcm: clean needs at least one of --older-than, --max-size, --max-count\n\nRun 'zcm clean --help' for examples.\n", .{}) catch {};
        env.stderr.flush() catch {};
        return 2;
    }

    const older_than = if (older_than_str) |s| humanize_dur.parseDuration(s) catch |err| {
        env.stderr.print("zcm: {s}\n", .{@errorName(err)}) catch {};
        env.stderr.flush() catch {};
        return 2;
    } else 0;

    const max_size = if (max_size_str) |s| humanize_size.parseSize(s) catch |err| {
        env.stderr.print("zcm: {s}\n", .{@errorName(err)}) catch {};
        env.stderr.flush() catch {};
        return 2;
    } else 0;

    const target = app.resolveTarget(allocator, env, common) catch |err| {
        env.stderr.print("zcm: {s}\n", .{@errorName(err)}) catch {};
        env.stderr.flush() catch {};
        return 1;
    };
    defer target.deinit(allocator);

    var res = scan_mod.scan(allocator, env.io, target.path) catch |err| {
        env.stderr.print("zcm: could not scan {s}: {s}\n", .{ target.path, @errorName(err) }) catch {};
        env.stderr.flush() catch {};
        return 1;
    };
    defer res.deinit(allocator);

    const now_ns: i128 = std.Io.Timestamp.now(env.io, .real).nanoseconds;
    const bucket_val: ?scan_mod.Bucket = if (bucket_filter) |bf| scan_mod.Bucket.fromCode(bf) else null;

    var plan = policy_mod.apply(allocator, res.entries, .{
        .older_than_ns = older_than,
        .max_size = max_size,
        .max_count = max_count,
        .bucket = bucket_val,
    }, now_ns) catch |err| {
        env.stderr.print("zcm: policy error: {s}\n", .{@errorName(err)}) catch {};
        env.stderr.flush() catch {};
        return 1;
    };
    defer plan.deinit(allocator);

    if (common.json) {
        var purged_result: ?purge_mod.PurgeResult = null;
        defer if (purged_result) |*p| p.deinit(allocator);

        var final_evict_count = plan.evict.len;
        var final_evict_bytes = plan.evictSize();

        if (!dry_run) {
            purged_result = purge_mod.purge(allocator, env.io, plan.evict);
            final_evict_count = purged_result.?.removed.items.len;
            final_evict_bytes = purged_result.?.reclaimed_size;
        }

        env.stdout.print(
            \\{{
            \\  "path": "{s}",
            \\  "dry_run": {s},
            \\  "evict_count": {d},
            \\  "evict_bytes": {d},
            \\  "keep_count": {d},
            \\  "entries": [
            \\
        , .{ target.path, if (dry_run) "true" else "false", final_evict_count, final_evict_bytes, plan.keep.len }) catch {};

        var time_buf: [32]u8 = undefined;
        for (plan.evict, 0..) |e, idx| {
            const rel_p = e.relPath(allocator) catch e.name;
            defer if (!std.mem.eql(u8, rel_p, e.name)) allocator.free(rel_p);
            const age_sec = @divFloor(now_ns - e.mod_time, std.time.ns_per_s);
            const ts_str = json_mod.formatRFC3339(e.mod_time, &time_buf);
            const comma = if (idx + 1 < plan.evict.len) "," else "";

            env.stdout.print(
                \\    {{
                \\      "entry": "{s}",
                \\      "bucket": "{s}",
                \\      "size_bytes": {d},
                \\      "age_seconds": {d},
                \\      "modified_at": "{s}"
                \\    }}{s}
                \\
            , .{ rel_p, e.bucket.code(), e.size, age_sec, ts_str, comma }) catch {};
        }

        env.stdout.print("  ]\n}}\n", .{}) catch {};
        env.stdout.flush() catch {};
        return 0;
    }

    const no_color = common.no_color or (env.getenv("NO_COLOR") != null and env.getenv("NO_COLOR").?.len > 0);
    const ui = ui_mod.UI.init(env.stdout, env.stderr, env.stdin, no_color);
    var head_buf: [256]u8 = undefined;
    const header_str = std.fmt.bufPrint(&head_buf, "{s} — {s}", .{ target.label, target.path }) catch target.path;
    ui.header(header_str);

    if (plan.evict.len == 0) {
        ui.success("Nothing to clean — every entry is already within policy.");
        return 0;
    }

    var kv_buf_remove: [128]u8 = undefined;
    var kv_buf_keep: [128]u8 = undefined;

    var keep_size: i64 = 0;
    for (plan.keep) |e| keep_size += e.size;

    const remove_str = std.fmt.bufPrint(&kv_buf_remove, "{d} entries ({s})", .{
        plan.evict.len,
        humanize_size.formatSize(plan.evictSize()).slice(),
    }) catch "";
    const keep_str = std.fmt.bufPrint(&kv_buf_keep, "{d} entries ({s})", .{
        plan.keep.len,
        humanize_size.formatSize(keep_size).slice(),
    }) catch "";

    ui.kv("To remove", remove_str);
    ui.kv("To keep", keep_str);

    const preview_limit = 10;
    const preview_count = @min(preview_limit, plan.evict.len);
    const preview = plan.evict[0..preview_count];

    var rows: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (rows.items) |row| {
            allocator.free(row[0]);
            allocator.free(row[1]);
            allocator.free(row[2]);
            allocator.free(row);
        }
        rows.deinit(allocator);
    }

    for (preview) |e| {
        const age_ns: i64 = @intCast(now_ns - e.mod_time);
        const rel_p = e.relPath(allocator) catch e.name;
        defer if (!std.mem.eql(u8, rel_p, e.name)) allocator.free(rel_p);

        const row = allocator.alloc([]const u8, 3) catch continue;
        row[0] = ui.paint(ui_mod.codeYellow, rel_p, allocator) catch rel_p;
        row[1] = allocator.dupe(u8, humanize_size.formatSize(e.size).slice()) catch "";
        row[2] = allocator.dupe(u8, humanize_dur.formatAge(age_ns).slice()) catch "";
        rows.append(allocator, row) catch {};
    }

    env.stdout.print("\n", .{}) catch {};
    ui.render(allocator, .{
        .columns = &[_]ui_mod.Column{
            .{ .header = "WILL REMOVE", .align_mode = .left },
            .{ .header = "SIZE", .align_mode = .right },
            .{ .header = "AGE", .align_mode = .right },
        },
        .rows = rows.items,
    }) catch {};

    if (plan.evict.len > preview.len) {
        var hint_buf: [64]u8 = undefined;
        const hint_str = std.fmt.bufPrint(&hint_buf, "...and {d} more.", .{plan.evict.len - preview.len}) catch "";
        ui.hint(hint_str);
    }

    if (dry_run) {
        ui.hint("Dry run: nothing was deleted. Re-run without --dry-run to apply.");
        return 0;
    }

    if (!yes) {
        if (!ui_mod.UI.isInputInteractive()) {
            ui.err("Refusing to delete without confirmation in a non-interactive session; pass --yes to proceed.");
            return 1;
        }
        var confirm_buf: [256]u8 = undefined;
        const prompt = std.fmt.bufPrint(&confirm_buf, "Delete {d} entries ({s}) from {s}? [y/N]", .{
            plan.evict.len,
            humanize_size.formatSize(plan.evictSize()).slice(),
            target.path,
        }) catch "Confirm delete? [y/N]";

        if (!ui.confirm(prompt)) {
            ui.warn("Aborted — nothing was deleted.");
            return 1;
        }
    }

    var purged = purge_mod.purge(allocator, env.io, plan.evict);
    defer purged.deinit(allocator);

    for (purged.failed.items) |f| {
        const rel_p = f.entry.relPath(allocator) catch f.entry.name;
        defer if (!std.mem.eql(u8, rel_p, f.entry.name)) allocator.free(rel_p);
        var err_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&err_buf, "{s}: {s}", .{ rel_p, f.err_msg }) catch rel_p;
        ui.err(msg);
    }

    var success_buf: [128]u8 = undefined;
    const succ_msg = std.fmt.bufPrint(&success_buf, "Removed {d} entries, freed {s}", .{
        purged.removed.items.len,
        humanize_size.formatSize(purged.reclaimed_size).slice(),
    }) catch "Purged entries";
    ui.success(succ_msg);

    if (purged.failed.items.len > 0) {
        var warn_buf: [64]u8 = undefined;
        const warn_msg = std.fmt.bufPrint(&warn_buf, "{d} entries could not be removed", .{purged.failed.items.len}) catch "Some entries failed";
        ui.warn(warn_msg);
        return 1;
    }
    return 0;
}
