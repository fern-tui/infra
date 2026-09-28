const std = @import("std");

pub const codeReset = "\x1b[0m";
pub const codeBold = "\x1b[1m";
pub const codeDim = "\x1b[2m";
pub const codeRed = "\x1b[31m";
pub const codeGreen = "\x1b[32m";
pub const codeYellow = "\x1b[33m";
pub const codeBlue = "\x1b[34m";
pub const codeMagenta = "\x1b[35m";
pub const codeCyan = "\x1b[36m";
pub const codeGray = "\x1b[90m";

pub const Align = enum {
    left,
    right,
};

pub const Column = struct {
    header: []const u8,
    align_mode: Align = .left,
};

pub const Table = struct {
    columns: []const Column,
    rows: []const []const []const u8,
    foot_rule: bool = false,
};

pub const UI = struct {
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
    in: *std.Io.Reader,
    color: bool,

    pub fn init(out: *std.Io.Writer, err_out: *std.Io.Writer, in: *std.Io.Reader, no_color: bool) UI {
        return UI{
            .out = out,
            .err_out = err_out,
            .in = in,
            .color = !no_color,
        };
    }

    pub fn isInputInteractive() bool {
        return true;
    }

    pub fn paint(self: *const UI, code: []const u8, s: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        if (!self.color or code.len == 0) {
            return allocator.dupe(u8, s);
        }
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ code, s, codeReset });
    }

    pub fn header(self: *const UI, msg: []const u8) void {
        if (self.color) {
            self.out.print("\n{s}::{s} {s}{s}{s}\n", .{ codeBlue, codeReset, codeGray, msg, codeReset }) catch {};
        } else {
            self.out.print("\n:: {s}\n", .{msg}) catch {};
        }
        self.out.flush() catch {};
    }

    pub fn cacheHeader(self: *const UI, label: []const u8, path: []const u8, count: usize, size_str: []const u8) void {
        if (self.color) {
            self.out.print("\n{s}::{s} {s}{s}{s} {s}—{s} {s}{s}{s} {s}({d} entries, {s}){s}\n", .{
                codeBlue,   codeReset,
                codeBold,   label,
                codeReset,  codeGray,
                codeReset,  codeCyan,
                path,       codeReset,
                codeYellow, count,
                size_str,   codeReset,
            }) catch {};
        } else {
            self.out.print("\n:: {s} — {s} ({d} entries, {s})\n", .{ label, path, count, size_str }) catch {};
        }
        self.out.flush() catch {};
    }

    pub fn kv(self: *const UI, key: []const u8, val: []const u8) void {
        var key_buf: [32]u8 = undefined;
        const formatted_key = std.fmt.bufPrint(&key_buf, "{s}:", .{key}) catch key;
        var padded: [32]u8 = undefined;
        @memset(&padded, ' ');
        const fill_len = @min(16, formatted_key.len);
        @memcpy(padded[0..fill_len], formatted_key[0..fill_len]);

        if (self.color) {
            self.out.print("  {s}{s}{s} {s}\n", .{ codeGray, padded[0..16], codeReset, val }) catch {};
        } else {
            self.out.print("  {s} {s}\n", .{ padded[0..16], val }) catch {};
        }
        self.out.flush() catch {};
    }

    pub fn hint(self: *const UI, msg: []const u8) void {
        if (self.color) {
            self.out.print("\n  {s}{s}{s}\n", .{ codeDim, msg, codeReset }) catch {};
        } else {
            self.out.print("\n  {s}\n", .{msg}) catch {};
        }
        self.out.flush() catch {};
    }

    pub fn success(self: *const UI, msg: []const u8) void {
        if (self.color) {
            self.out.print("\n  {s}✓{s} {s}\n", .{ codeGreen, codeReset, msg }) catch {};
        } else {
            self.out.print("\n  ✓ {s}\n", .{msg}) catch {};
        }
        self.out.flush() catch {};
    }

    pub fn warn(self: *const UI, msg: []const u8) void {
        if (self.color) {
            self.out.print("\n  {s}!{s} {s}\n", .{ codeYellow, codeReset, msg }) catch {};
        } else {
            self.out.print("\n  ! {s}\n", .{msg}) catch {};
        }
        self.out.flush() catch {};
    }

    pub fn err(self: *const UI, msg: []const u8) void {
        if (self.color) {
            self.err_out.print("\n  {s}✗{s} {s}\n", .{ codeRed, codeReset, msg }) catch {};
        } else {
            self.err_out.print("\n  ✗ {s}\n", .{msg}) catch {};
        }
        self.err_out.flush() catch {};
    }

    pub fn confirm(self: *const UI, prompt: []const u8) bool {
        if (self.color) {
            self.out.print("  {s}?{s} {s} ", .{ codeYellow, codeReset, prompt }) catch {};
        } else {
            self.out.print("  ? {s} ", .{prompt}) catch {};
        }
        self.out.flush() catch {};

        const line = self.in.takeDelimiterExclusive('\n') catch return false;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        return std.ascii.eqlIgnoreCase(trimmed, "y") or std.ascii.eqlIgnoreCase(trimmed, "yes");
    }

    pub fn render(self: *const UI, allocator: std.mem.Allocator, table: Table) !void {
        const widths = try allocator.alloc(usize, table.columns.len);
        defer allocator.free(widths);

        for (table.columns, 0..) |col, i| {
            widths[i] = visibleLen(col.header);
        }
        for (table.rows) |row| {
            for (row, 0..) |cell, i| {
                if (i < widths.len) {
                    const n = visibleLen(cell);
                    if (n > widths[i]) widths[i] = n;
                }
            }
        }

        // Header
        self.out.print("  ", .{}) catch {};
        for (table.columns, 0..) |col, i| {
            try self.printCell(col.header, widths[i], col.align_mode, i == table.columns.len - 1, codeBold);
            if (i < table.columns.len - 1) self.out.print("  ", .{}) catch {};
        }
        self.out.print("\n", .{}) catch {};

        // Divider
        var total_width: usize = 0;
        for (widths, 0..) |w, i| {
            total_width += w;
            if (i < widths.len - 1) total_width += 2;
        }
        self.out.print("  ", .{}) catch {};
        if (self.color) self.out.print("{s}", .{codeGray}) catch {};
        var d: usize = 0;
        while (d < total_width) : (d += 1) {
            self.out.print("─", .{}) catch {};
        }
        if (self.color) self.out.print("{s}", .{codeReset}) catch {};
        self.out.print("\n", .{}) catch {};

        // Rows
        for (table.rows, 0..) |row, r_idx| {
            if (table.foot_rule and r_idx == table.rows.len - 1) {
                self.out.print("  ", .{}) catch {};
                if (self.color) self.out.print("{s}", .{codeGray}) catch {};
                var fd: usize = 0;
                while (fd < total_width) : (fd += 1) {
                    self.out.print("─", .{}) catch {};
                }
                if (self.color) self.out.print("{s}", .{codeReset}) catch {};
                self.out.print("\n", .{}) catch {};
            }

            self.out.print("  ", .{}) catch {};
            for (table.columns, 0..) |col, c_idx| {
                const cell = if (c_idx < row.len) row[c_idx] else "";
                try self.printCell(cell, widths[c_idx], col.align_mode, c_idx == table.columns.len - 1, "");
                if (c_idx < table.columns.len - 1) self.out.print("  ", .{}) catch {};
            }
            if (self.color) self.out.print("{s}", .{codeReset}) catch {};
            self.out.print("\n", .{}) catch {};
        }
        self.out.flush() catch {};
    }

    fn printCell(self: *const UI, s: []const u8, width: usize, align_mode: Align, is_last: bool, wrap_code: []const u8) !void {
        const vlen = visibleLen(s);
        const pad_len = if (width > vlen) width - vlen else 0;

        if (align_mode == .right) {
            var i: usize = 0;
            while (i < pad_len) : (i += 1) self.out.print(" ", .{}) catch {};
        }

        if (self.color and wrap_code.len > 0) self.out.print("{s}", .{wrap_code}) catch {};
        self.out.print("{s}", .{s}) catch {};
        if (self.color and wrap_code.len > 0) self.out.print("{s}", .{codeReset}) catch {};

        if (align_mode == .left and !is_last) {
            var i: usize = 0;
            while (i < pad_len) : (i += 1) self.out.print(" ", .{}) catch {};
        }
    }

    pub fn entryPath(self: *const UI, allocator: std.mem.Allocator, bucket: []const u8, name: []const u8) ![]const u8 {
        if (!self.color) {
            return std.fmt.allocPrint(allocator, "{s}/{s}", .{ bucket, name });
        }

        const prefix_code = if (std.mem.eql(u8, bucket, "o") or std.mem.eql(u8, bucket, "p"))
            codeCyan
        else if (std.mem.eql(u8, bucket, "h"))
            codeBlue
        else if (std.mem.eql(u8, bucket, "z"))
            codeMagenta
        else if (std.mem.eql(u8, bucket, "tmp"))
            codeYellow
        else
            codeGray;

        if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
            const stem = name[0..dot];
            const ext = name[dot..];
            return std.fmt.allocPrint(allocator, "{s}{s}/{s}{s}{s}{s}{s}", .{
                prefix_code, bucket, codeReset, stem, codeGray, ext, codeReset,
            });
        }
        return std.fmt.allocPrint(allocator, "{s}{s}/{s}{s}", .{ prefix_code, bucket, codeReset, name });
    }

    pub fn ageColor(self: *const UI, allocator: std.mem.Allocator, s: []const u8, age_ns: i64) ![]const u8 {
        if (!self.color) return allocator.dupe(u8, s);
        const day_ns = 24 * std.time.ns_per_hour;
        if (age_ns < day_ns) {
            return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ codeGreen, s, codeReset });
        } else if (age_ns < 7 * day_ns) {
            return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ codeYellow, s, codeReset });
        } else {
            return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ codeRed, s, codeReset });
        }
    }
};

pub fn visibleLen(s: []const u8) usize {
    var n: usize = 0;
    var in_seq = false;
    for (s) |c| {
        if (c == 0x1b) {
            in_seq = true;
            continue;
        }
        if (in_seq) {
            if (c == 'm') {
                in_seq = false;
            }
            continue;
        }
        n += 1;
    }
    return n;
}
