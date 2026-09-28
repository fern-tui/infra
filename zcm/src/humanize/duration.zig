const std = @import("std");

pub const secs_per_minute: i64 = 60;
pub const secs_per_hour: i64 = 60 * secs_per_minute;
pub const secs_per_day: i64 = 24 * secs_per_hour;
pub const secs_per_month: i64 = 30 * secs_per_day;
pub const secs_per_year: i64 = 365 * secs_per_day;

pub const FormattedDuration = struct {
    buf: [32]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const FormattedDuration) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Format duration in nanoseconds as compact age ("30s", "23h", "9d", "1mo", "1y").
pub fn formatAge(duration_ns: i128) FormattedDuration {
    var res = FormattedDuration{};
    const secs_raw = @divFloor(duration_ns, std.time.ns_per_s);
    const secs: i64 = if (secs_raw < 0) 0 else @intCast(secs_raw);

    const formatted = if (secs < secs_per_minute)
        std.fmt.bufPrint(&res.buf, "{d}s", .{secs}) catch unreachable
    else if (secs < secs_per_hour)
        std.fmt.bufPrint(&res.buf, "{d}m", .{@divFloor(secs, secs_per_minute)}) catch unreachable
    else if (secs < secs_per_day)
        std.fmt.bufPrint(&res.buf, "{d}h", .{@divFloor(secs, secs_per_hour)}) catch unreachable
    else if (secs < secs_per_month)
        std.fmt.bufPrint(&res.buf, "{d}d", .{@divFloor(secs, secs_per_day)}) catch unreachable
    else if (secs < secs_per_year)
        std.fmt.bufPrint(&res.buf, "{d}mo", .{@divFloor(secs, secs_per_month)}) catch unreachable
    else
        std.fmt.bufPrint(&res.buf, "{d}y", .{@divFloor(secs, secs_per_year)}) catch unreachable;

    res.len = formatted.len;
    return res;
}

pub const DurationError = error{
    InvalidDuration,
    NegativeDuration,
};

/// Parses strings like "30m", "24h", "1h30m", "7d", "2w" into nanoseconds.
pub fn parseDuration(input: []const u8) DurationError!i64 {
    const s = std.mem.trim(u8, input, " \t\r\n");
    if (s.len == 0) return 0;
    if (s[0] == '-') return error.NegativeDuration;

    var lower_buf: [64]u8 = undefined;
    if (s.len > lower_buf.len) return error.InvalidDuration;
    const lower = std.ascii.lowerString(&lower_buf, s);

    if (parseLeadingFloat(lower, "d")) |days| {
        return @intFromFloat(days * 24.0 * @as(f64, @floatFromInt(std.time.ns_per_hour)));
    }
    if (parseLeadingFloat(lower, "w")) |weeks| {
        return @intFromFloat(weeks * 7.0 * 24.0 * @as(f64, @floatFromInt(std.time.ns_per_hour)));
    }

    return parseStandardDuration(lower);
}

fn parseLeadingFloat(lower: []const u8, suffix: []const u8) ?f64 {
    if (!std.mem.endsWith(u8, lower, suffix)) return null;
    const num_part = lower[0 .. lower.len - suffix.len];
    if (num_part.len == 0) return null;
    const val = std.fmt.parseFloat(f64, num_part) catch return null;
    if (val < 0) return null;
    return val;
}

fn parseStandardDuration(s: []const u8) DurationError!i64 {
    var total_ns: i64 = 0;
    var i: usize = 0;
    var matched_any = false;

    while (i < s.len) {
        const start = i;
        while (i < s.len and ((s[i] >= '0' and s[i] <= '9') or s[i] == '.')) : (i += 1) {}
        const num_str = s[start..i];
        if (num_str.len == 0) return error.InvalidDuration;

        const val = std.fmt.parseFloat(f64, num_str) catch return error.InvalidDuration;
        const unit_start = i;
        while (i < s.len and (s[i] >= 'a' and s[i] <= 'z')) : (i += 1) {}
        const unit = s[unit_start..i];
        if (unit.len == 0) return error.InvalidDuration;

        const multiplier: f64 = if (std.mem.eql(u8, unit, "ns"))
            1.0
        else if (std.mem.eql(u8, unit, "us") or std.mem.eql(u8, unit, "µs"))
            @floatFromInt(std.time.ns_per_us)
        else if (std.mem.eql(u8, unit, "ms"))
            @floatFromInt(std.time.ns_per_ms)
        else if (std.mem.eql(u8, unit, "s"))
            @floatFromInt(std.time.ns_per_s)
        else if (std.mem.eql(u8, unit, "m"))
            @floatFromInt(std.time.ns_per_min)
        else if (std.mem.eql(u8, unit, "h"))
            @floatFromInt(std.time.ns_per_hour)
        else
            return error.InvalidDuration;

        total_ns += @intFromFloat(val * multiplier);
        matched_any = true;
    }

    if (!matched_any) return error.InvalidDuration;
    return total_ns;
}

test "formatAge" {
    try std.testing.expectEqualStrings("30s", formatAge(30 * std.time.ns_per_s).slice());
    try std.testing.expectEqualStrings("1m", formatAge(90 * std.time.ns_per_s).slice());
    try std.testing.expectEqualStrings("23h", formatAge(23 * std.time.ns_per_hour).slice());
    try std.testing.expectEqualStrings("1d", formatAge(25 * std.time.ns_per_hour).slice());
    try std.testing.expectEqualStrings("9d", formatAge(9 * 24 * std.time.ns_per_hour).slice());
    try std.testing.expectEqualStrings("1mo", formatAge(40 * 24 * std.time.ns_per_hour).slice());
    try std.testing.expectEqualStrings("1y", formatAge(400 * 24 * std.time.ns_per_hour).slice());
    try std.testing.expectEqualStrings("0s", formatAge(-5 * std.time.ns_per_s).slice());
}

test "parseDuration" {
    try std.testing.expectEqual(@as(i64, 0), try parseDuration(""));
    try std.testing.expectEqual(@as(i64, 30 * std.time.ns_per_min), try parseDuration("30m"));
    try std.testing.expectEqual(@as(i64, 24 * std.time.ns_per_hour), try parseDuration("24h"));
    try std.testing.expectEqual(@as(i64, 90 * std.time.ns_per_min), try parseDuration("1h30m"));
    try std.testing.expectEqual(@as(i64, 7 * 24 * std.time.ns_per_hour), try parseDuration("7d"));
    try std.testing.expectEqual(@as(i64, 14 * 24 * std.time.ns_per_hour), try parseDuration("2w"));
    try std.testing.expectEqual(@as(i64, 36 * std.time.ns_per_hour), try parseDuration("1.5d"));
    try std.testing.expectEqual(@as(i64, 0), try parseDuration("0s"));
}

test "parseDurationErrors" {
    try std.testing.expectError(error.InvalidDuration, parseDuration("abc"));
    try std.testing.expectError(error.NegativeDuration, parseDuration("-7d"));
    try std.testing.expectError(error.InvalidDuration, parseDuration("1d12h"));
}
