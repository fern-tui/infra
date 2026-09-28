const std = @import("std");
const app = @import("app.zig");
const scan_mod = @import("../cache/scan.zig");
const humanize_size = @import("../humanize/size.zig");
const humanize_dur = @import("../humanize/duration.zig");
const ui_mod = @import("../ui/ui.zig");
const json_mod = @import("json.zig");
const help_mod = @import("help.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8, env: app.Env) u8 {
    var common = app.CommonFlags{};
    var sort_by: []const u8 = "size";
    var bucket_filter: ?[]const u8 = null;
    var limit: usize = 30;
    var ascending: bool = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--global")) {
            common.global = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            common.no_color = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            common.json = true;
        } else if (std.mem.eql(u8, arg, "--asc")) {
            ascending = true;
        } else if (std.mem.eql(u8, arg, "--cache-dir") and i + 1 < args.len) {
            i += 1;
            common.cache_dir = args[i];
        } else if (std.mem.startsWith(u8, arg, "--cache-dir=")) {
            common.cache_dir = arg["--cache-dir=".len..];
        } else if (std.mem.eql(u8, arg, "--sort") and i + 1 < args.len) {
            i += 1;
            sort_by = args[i];
        } else if (std.mem.startsWith(u8, arg, "--sort=")) {
            sort_by = arg["--sort=".len..];
        } else if (std.mem.eql(u8, arg, "--bucket") and i + 1 < args.len) {
            i += 1;
            bucket_filter = args[i];
        } else if (std.mem.startsWith(u8, arg, "--bucket=")) {
            bucket_filter = arg["--bucket=".len..];
        } else if (std.mem.eql(u8, arg, "--limit") and i + 1 < args.len) {
            i += 1;
            limit = std.fmt.parseInt(usize, args[i], 10) catch 30;
        } else if (std.mem.startsWith(u8, arg, "--limit=")) {
            limit = std.fmt.parseInt(usize, arg["--limit=".len..], 10) catch 30;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            _ = help_mod.printHelpFor("list", env.stdout);
            return 0;
        }
    }

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

    var filtered: std.ArrayList(scan_mod.Entry) = .empty;
    defer filtered.deinit(allocator);

    for (res.entries) |e| {
        if (bucket_filter) |bf| {
            if (!std.mem.eql(u8, e.bucket.code(), bf)) continue;
        }
        filtered.append(allocator, e) catch {};
    }

    if (std.mem.eql(u8, sort_by, "size")) {
        std.sort.block(scan_mod.Entry, filtered.items, {}, sortSize);
    } else if (std.mem.eql(u8, sort_by, "age")) {
        std.sort.block(scan_mod.Entry, filtered.items, {}, sortAge);
    } else if (std.mem.eql(u8, sort_by, "name")) {
        std.sort.block(scan_mod.Entry, filtered.items, {}, sortName);
    } else {
        env.stderr.print("zcm: unknown --sort value \"{s}\" (want size, age, or name)\n", .{sort_by}) catch {};
        env.stderr.flush() catch {};
        return 2;
    }

    if (ascending) {
        std.mem.reverse(scan_mod.Entry, filtered.items);
    }

    const total_filtered = filtered.items.len;
    var count_to_show = total_filtered;
    if (limit > 0 and count_to_show > limit) {
        count_to_show = limit;
    }
    const shown = filtered.items[0..count_to_show];

    const now_ns: i128 = std.Io.Timestamp.now(env.io, .real).nanoseconds;

    if (common.json) {
        env.stdout.print("[\n", .{}) catch {};
        var time_buf: [32]u8 = undefined;
        for (shown, 0..) |e, idx| {
            const rel_p = e.relPath(allocator) catch e.name;
            defer if (!std.mem.eql(u8, rel_p, e.name)) allocator.free(rel_p);
            const age_sec = @divFloor(now_ns - e.mod_time, std.time.ns_per_s);
            const ts_str = json_mod.formatRFC3339(e.mod_time, &time_buf);
            const comma = if (idx + 1 < shown.len) "," else "";

            env.stdout.print(
                \\  {{
                \\    "entry": "{s}",
                \\    "bucket": "{s}",
                \\    "size_bytes": {d},
                \\    "age_seconds": {d},
                \\    "modified_at": "{s}"
                \\  }}{s}
                \\
            , .{ rel_p, e.bucket.code(), e.size, age_sec, ts_str, comma }) catch {};
        }
        env.stdout.print("]\n", .{}) catch {};
        env.stdout.flush() catch {};
        return 0;
    }

    const no_color = common.no_color or (env.getenv("NO_COLOR") != null and env.getenv("NO_COLOR").?.len > 0);
    const ui = ui_mod.UI.init(env.stdout, env.stderr, env.stdin, no_color);
    ui.cacheHeader(target.label, target.path, res.entries.len, humanize_size.formatSize(res.total_size).slice());

    if (shown.len == 0) {
        ui.hint("No entries match.");
        return 0;
    }

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

    var shown_size: i64 = 0;
    for (shown) |e| {
        const age_ns: i64 = @intCast(now_ns - e.mod_time);
        shown_size += e.size;

        const size_formatted = humanize_size.formatSize(e.size);
        const age_formatted = humanize_dur.formatAge(age_ns);

        const row = allocator.alloc([]const u8, 3) catch continue;
        if (std.mem.containsAtLeast(u8, e.name, 1, ".")) {
            const rel_p = e.relPath(allocator) catch e.name;
            defer if (!std.mem.eql(u8, rel_p, e.name)) allocator.free(rel_p);
            row[0] = ui.paint(ui_mod.codeGray, rel_p, allocator) catch rel_p;
            row[1] = ui.paint(ui_mod.codeGray, size_formatted.slice(), allocator) catch "";
            row[2] = ui.paint(ui_mod.codeGray, age_formatted.slice(), allocator) catch "";
        } else {
            row[0] = ui.entryPath(allocator, e.bucket.code(), e.name) catch e.name;
            row[1] = ui.ageColor(allocator, size_formatted.slice(), age_ns) catch "";
            row[2] = ui.ageColor(allocator, age_formatted.slice(), age_ns) catch "";
        }
        rows.append(allocator, row) catch {};
    }

    // Summary footer row
    const foot_row = allocator.alloc([]const u8, 3) catch null;
    if (foot_row) |frow| {
        const foot_entry_str = std.fmt.allocPrint(allocator, "{d} of {d} entries", .{ shown.len, total_filtered }) catch "";
        frow[0] = ui.paint(ui_mod.codeGray, foot_entry_str, allocator) catch "";
        if (foot_entry_str.len > 0) allocator.free(foot_entry_str);
        frow[1] = ui.paint(ui_mod.codeGray, humanize_size.formatSize(shown_size).slice(), allocator) catch "";
        frow[2] = allocator.dupe(u8, "") catch "";
        rows.append(allocator, frow) catch {};
    }

    env.stdout.print("\n", .{}) catch {};
    ui.render(allocator, .{
        .columns = &[_]ui_mod.Column{
            .{ .header = "ENTRY", .align_mode = .left },
            .{ .header = "SIZE", .align_mode = .right },
            .{ .header = "AGE", .align_mode = .right },
        },
        .rows = rows.items,
        .foot_rule = true,
    }) catch {};

    if (limit > 0 and total_filtered > limit) {
        var hint_buf: [128]u8 = undefined;
        const hint_str = std.fmt.bufPrint(&hint_buf, "Showing {d} of {d} entries — pass --limit 0 to see all.", .{ limit, total_filtered }) catch "";
        ui.hint(hint_str);
    }
    return 0;
}

fn sortSize(_: void, a: scan_mod.Entry, b: scan_mod.Entry) bool {
    return a.size > b.size;
}
fn sortAge(_: void, a: scan_mod.Entry, b: scan_mod.Entry) bool {
    return a.mod_time < b.mod_time;
}
fn sortName(_: void, a: scan_mod.Entry, b: scan_mod.Entry) bool {
    if (a.bucket == b.bucket) return std.mem.lessThan(u8, a.name, b.name);
    return std.mem.lessThan(u8, a.bucket.code(), b.bucket.code());
}
