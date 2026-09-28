const std = @import("std");

pub const kb: i64 = 1 << 10;
pub const mb: i64 = 1 << 20;
pub const gb: i64 = 1 << 30;
pub const tb: i64 = 1 << 40;

const Unit = struct {
    suffix: []const u8,
    multiplier: f64,
};

const size_units = [_]Unit{
    .{ .suffix = "GIB", .multiplier = @floatFromInt(gb) },
    .{ .suffix = "GB", .multiplier = @floatFromInt(gb) },
    .{ .suffix = "G", .multiplier = @floatFromInt(gb) },
    .{ .suffix = "MIB", .multiplier = @floatFromInt(mb) },
    .{ .suffix = "MB", .multiplier = @floatFromInt(mb) },
    .{ .suffix = "M", .multiplier = @floatFromInt(mb) },
    .{ .suffix = "KIB", .multiplier = @floatFromInt(kb) },
    .{ .suffix = "KB", .multiplier = @floatFromInt(kb) },
    .{ .suffix = "K", .multiplier = @floatFromInt(kb) },
    .{ .suffix = "TIB", .multiplier = @floatFromInt(tb) },
    .{ .suffix = "TB", .multiplier = @floatFromInt(tb) },
    .{ .suffix = "T", .multiplier = @floatFromInt(tb) },
    .{ .suffix = "B", .multiplier = 1.0 },
};

pub const FormattedSize = struct {
    buf: [32]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const FormattedSize) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Format byte counts using binary units (1024-based) with 1 decimal place.
pub fn formatSize(bytes: i64) FormattedSize {
    var res = FormattedSize{};
    const b: i64 = if (bytes < 0) 0 else bytes;
    const f: f64 = @floatFromInt(b);

    const formatted = if (b < kb)
        std.fmt.bufPrint(&res.buf, "{d} B", .{b}) catch unreachable
    else if (b < mb)
        std.fmt.bufPrint(&res.buf, "{d:.1} KB", .{f / @as(f64, @floatFromInt(kb))}) catch unreachable
    else if (b < gb)
        std.fmt.bufPrint(&res.buf, "{d:.1} MB", .{f / @as(f64, @floatFromInt(mb))}) catch unreachable
    else if (b < tb)
        std.fmt.bufPrint(&res.buf, "{d:.1} GB", .{f / @as(f64, @floatFromInt(gb))}) catch unreachable
    else
        std.fmt.bufPrint(&res.buf, "{d:.1} TB", .{f / @as(f64, @floatFromInt(tb))}) catch unreachable;

    res.len = formatted.len;
    return res;
}

pub const SizeError = error{
    MissingSizeNumber,
    NegativeSize,
    InvalidSize,
};

/// Parses human sizes like "5G", "512MB", "1.5GiB" or raw byte counts into i64 bytes.
pub fn parseSize(input: []const u8) SizeError!i64 {
    const s = std.mem.trim(u8, input, " \t\r\n");
    if (s.len == 0) return 0;

    var upper_buf: [64]u8 = undefined;
    if (s.len > upper_buf.len) return error.InvalidSize;
    const upper = std.ascii.upperString(&upper_buf, s);

    for (size_units) |unit| {
        if (std.mem.endsWith(u8, upper, unit.suffix)) {
            const num_part = std.mem.trim(u8, s[0 .. s.len - unit.suffix.len], " \t\r\n");
            if (num_part.len == 0) return error.MissingSizeNumber;
            const val = std.fmt.parseFloat(f64, num_part) catch return error.InvalidSize;
            if (val < 0) return error.NegativeSize;
            return @intFromFloat(val * unit.multiplier);
        }
    }

    const val = std.fmt.parseInt(i64, s, 10) catch return error.InvalidSize;
    if (val < 0) return error.NegativeSize;
    return val;
}

test "formatSize" {
    try std.testing.expectEqualStrings("0 B", formatSize(0).slice());
    try std.testing.expectEqualStrings("512 B", formatSize(512).slice());
    try std.testing.expectEqualStrings("1.0 KB", formatSize(1024).slice());
    try std.testing.expectEqualStrings("1.5 KB", formatSize(1536).slice());
    try std.testing.expectEqualStrings("1.0 MB", formatSize(1 << 20).slice());
    try std.testing.expectEqualStrings("1.0 GB", formatSize(1 << 30).slice());
    try std.testing.expectEqualStrings("5.0 GB", formatSize(5 * (1 << 30)).slice());
    try std.testing.expectEqualStrings("1.0 TB", formatSize(1 << 40).slice());
}

test "parseSize" {
    try std.testing.expectEqual(@as(i64, 0), try parseSize(""));
    try std.testing.expectEqual(@as(i64, 0), try parseSize("0"));
    try std.testing.expectEqual(@as(i64, 512), try parseSize("512"));
    try std.testing.expectEqual(@as(i64, 1024), try parseSize("1K"));
    try std.testing.expectEqual(@as(i64, 1024), try parseSize("1KB"));
    try std.testing.expectEqual(@as(i64, 1024), try parseSize("1KiB"));
    try std.testing.expectEqual(@as(i64, 1024), try parseSize("1k"));
    try std.testing.expectEqual(@as(i64, 5 * (1 << 30)), try parseSize("5G"));
    try std.testing.expectEqual(@as(i64, 5 * (1 << 30)), try parseSize("5GB"));
    try std.testing.expectEqual(@as(i64, @intFromFloat(1.5 * (1 << 30))), try parseSize("1.5G"));
    try std.testing.expectEqual(@as(i64, 500 * (1 << 20)), try parseSize("500M"));
    try std.testing.expectEqual(@as(i64, 1 << 40), try parseSize("1T"));
    try std.testing.expectEqual(@as(i64, 2 * (1 << 40)), try parseSize("2TB"));
}

test "parseSizeErrors" {
    try std.testing.expectError(error.InvalidSize, parseSize("abc"));
    try std.testing.expectError(error.NegativeSize, parseSize("-5G"));
    try std.testing.expectError(error.InvalidSize, parseSize("5XB"));
    try std.testing.expectError(error.InvalidSize, parseSize("G5"));
}

test "parseSizeRoundTrip" {
    const got = try parseSize("5G");
    try std.testing.expectEqualStrings("5.0 GB", formatSize(got).slice());
}
