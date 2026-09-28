const std = @import("std");

/// Format epoch timestamp in nanoseconds into RFC3339 UTC string.
pub fn formatRFC3339(mod_time_ns: i128, buf: *[32]u8) []const u8 {
    const epoch_secs = std.time.epoch.EpochSeconds{
        .secs = @intCast(@max(0, @divFloor(mod_time_ns, std.time.ns_per_s))),
    };
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_secs.getDaySeconds();

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch "1970-01-01T00:00:00Z";
}
