const std = @import("std");
const app = @import("app.zig");
const scan_mod = @import("../cache/scan.zig");
const humanize_size = @import("../humanize/size.zig");
const ui_mod = @import("../ui/ui.zig");
const help_mod = @import("help.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8, env: app.Env) u8 {
    var common = app.CommonFlags{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--global")) {
            common.global = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            common.no_color = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            common.json = true;
        } else if (std.mem.eql(u8, arg, "--cache-dir") and i + 1 < args.len) {
            i += 1;
            common.cache_dir = args[i];
        } else if (std.mem.startsWith(u8, arg, "--cache-dir=")) {
            common.cache_dir = arg["--cache-dir=".len..];
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            _ = help_mod.printHelpFor("info", env.stdout);
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

    if (common.json) {
        env.stdout.print(
            \\{{
            \\  "path": "{s}",
            \\  "kind": "{s}",
            \\  "resolved_via": "{s}",
            \\  "entries": {d},
            \\  "total_size_bytes": {d},
            \\  "buckets": {{
            \\
        , .{
            target.path,
            target.label,
            target.source,
            res.entries.len,
            res.total_size,
        }) catch {};

        var bucket_it = res.by_bucket.iterator();
        var count: usize = 0;
        while (bucket_it.next()) |entry| : (count += 1) {
            const b = entry.key_ptr.*;
            const st = entry.value_ptr.*;
            const comma = if (count + 1 < res.by_bucket.count()) "," else "";
            env.stdout.print(
                \\    "{s}": {{
                \\      "count": {d},
                \\      "size_bytes": {d},
                \\      "purpose": "{s}"
                \\    }}{s}
                \\
            , .{ b.code(), st.count, st.size, b.purpose(), comma }) catch {};
        }

        env.stdout.print("  }}\n}}\n", .{}) catch {};
        env.stdout.flush() catch {};
        return 0;
    }

    const no_color = common.no_color or (env.getenv("NO_COLOR") != null and env.getenv("NO_COLOR").?.len > 0);
    const ui = ui_mod.UI.init(env.stdout, env.stderr, env.stdin, no_color);
    var head_buf: [256]u8 = undefined;
    const header_str = std.fmt.bufPrint(&head_buf, "{s} — {s}", .{ target.label, target.path }) catch target.path;
    ui.header(header_str);

    var entries_count_buf: [32]u8 = undefined;
    const entries_count_str = std.fmt.bufPrint(&entries_count_buf, "{d}", .{res.entries.len}) catch "0";
    ui.kv("Entries", entries_count_str);
    ui.kv("Total size", humanize_size.formatSize(res.total_size).slice());

    if (res.by_bucket.count() > 0) {
        var buckets: std.ArrayList(scan_mod.Bucket) = .empty;
        defer buckets.deinit(allocator);

        var it = res.by_bucket.keyIterator();
        while (it.next()) |b| buckets.append(allocator, b.*) catch {};

        const Context = struct {
            map: *const std.AutoHashMapUnmanaged(scan_mod.Bucket, scan_mod.BucketStats),
            pub fn lessThan(ctx: @This(), a: scan_mod.Bucket, b: scan_mod.Bucket) bool {
                return ctx.map.get(a).?.size > ctx.map.get(b).?.size;
            }
        };
        std.sort.block(scan_mod.Bucket, buckets.items, Context{ .map = &res.by_bucket }, Context.lessThan);

        var rows: std.ArrayList([]const []const u8) = .empty;
        defer {
            for (rows.items) |row| {
                allocator.free(row[1]);
                allocator.free(row[2]);
                allocator.free(row);
            }
            rows.deinit(allocator);
        }

        for (buckets.items) |b| {
            const st = res.by_bucket.get(b).?;
            const count_str = std.fmt.allocPrint(allocator, "{d}", .{st.count}) catch "0";
            const size_str = allocator.dupe(u8, humanize_size.formatSize(st.size).slice()) catch "";

            const row = allocator.alloc([]const u8, 4) catch continue;
            row[0] = b.code();
            row[1] = count_str;
            row[2] = size_str;
            row[3] = b.purpose();
            rows.append(allocator, row) catch {};
        }

        env.stdout.print("\n", .{}) catch {};
        ui.render(allocator, .{
            .columns = &[_]ui_mod.Column{
                .{ .header = "BUCKET", .align_mode = .left },
                .{ .header = "ENTRIES", .align_mode = .right },
                .{ .header = "SIZE", .align_mode = .right },
                .{ .header = "PURPOSE", .align_mode = .left },
            },
            .rows = rows.items,
        }) catch {};
    }

    ui.hint("Run 'zcm list' to see individual entries, or 'zcm clean --help' to free up space.");
    return 0;
}
