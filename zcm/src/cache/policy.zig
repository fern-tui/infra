const std = @import("std");
const scan_mod = @import("scan.zig");
pub const Entry = scan_mod.Entry;
pub const Bucket = scan_mod.Bucket;

pub const Policy = struct {
    older_than_ns: i64 = 0,
    max_size: i64 = 0,
    max_count: usize = 0,
    bucket: ?Bucket = null,
};

pub const Plan = struct {
    evict: []Entry,
    keep: []Entry,

    pub fn evictSize(self: Plan) i64 {
        var total: i64 = 0;
        for (self.evict) |e| total += e.size;
        return total;
    }

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.evict);
        allocator.free(self.keep);
    }
};

pub fn apply(allocator: std.mem.Allocator, entries: []const Entry, policy: Policy, now_ns: i128) !Plan {
    var candidates: std.ArrayList(Entry) = .empty;
    defer candidates.deinit(allocator);

    for (entries) |e| {
        if (policy.bucket != null and e.bucket != policy.bucket.?) continue;
        try candidates.append(allocator, e);
    }

    const is_evicted = try allocator.alloc(bool, candidates.items.len);
    defer allocator.free(is_evicted);
    @memset(is_evicted, false);

    if (policy.older_than_ns > 0) {
        for (candidates.items, 0..) |e, idx| {
            if (now_ns - e.mod_time >= policy.older_than_ns) {
                is_evicted[idx] = true;
            }
        }
    }

    var remaining: std.ArrayList(usize) = .empty;
    defer remaining.deinit(allocator);

    for (candidates.items, 0..) |_, idx| {
        if (!is_evicted[idx]) {
            try remaining.append(allocator, idx);
        }
    }

    const Context = struct {
        items: []const Entry,
        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return ctx.items[a].mod_time < ctx.items[b].mod_time;
        }
    };
    std.sort.block(usize, remaining.items, Context{ .items = candidates.items }, Context.lessThan);

    if (policy.max_size > 0) {
        var total: i64 = 0;
        for (remaining.items) |idx| {
            total += candidates.items[idx].size;
        }
        var i: usize = 0;
        while (total > policy.max_size and i < remaining.items.len) : (i += 1) {
            const idx = remaining.items[i];
            is_evicted[idx] = true;
            total -= candidates.items[idx].size;
        }
        if (i > 0) {
            const count = remaining.items.len - i;
            std.mem.copyForwards(usize, remaining.items[0..count], remaining.items[i..]);
            remaining.items.len = count;
        }
    }

    if (policy.max_count > 0) {
        var i: usize = 0;
        while (remaining.items.len - i > policy.max_count) : (i += 1) {
            const idx = remaining.items[i];
            is_evicted[idx] = true;
        }
    }

    var evict_list: std.ArrayList(Entry) = .empty;
    defer evict_list.deinit(allocator);
    var keep_list: std.ArrayList(Entry) = .empty;
    defer keep_list.deinit(allocator);

    for (candidates.items, 0..) |e, idx| {
        if (is_evicted[idx]) {
            try evict_list.append(allocator, e);
        } else {
            try keep_list.append(allocator, e);
        }
    }

    const evict_slice = try evict_list.toOwnedSlice(allocator);
    const keep_slice = try keep_list.toOwnedSlice(allocator);

    std.sort.block(Entry, evict_slice, {}, sortEntrySizeDesc);
    std.sort.block(Entry, keep_slice, {}, sortEntrySizeDesc);

    return Plan{
        .evict = evict_slice,
        .keep = keep_slice,
    };
}

fn sortEntrySizeDesc(_: void, a: Entry, b: Entry) bool {
    return a.size > b.size;
}

test "policy tests" {
    const allocator = std.testing.allocator;
    const now: i128 = 1_700_000_000 * std.time.ns_per_s;

    const entries = [_]Entry{
        .{ .bucket = .outputs, .name = "fresh", .path = "o/fresh", .size = 100, .mod_time = now - 1 * std.time.ns_per_hour },
        .{ .bucket = .outputs, .name = "stale", .path = "o/stale", .size = 100, .mod_time = now - 10 * 24 * std.time.ns_per_hour },
    };

    var plan = try apply(allocator, &entries, .{ .older_than_ns = 7 * 24 * std.time.ns_per_hour }, now);
    defer plan.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), plan.evict.len);
    try std.testing.expectEqualStrings("stale", plan.evict[0].name);
    try std.testing.expectEqual(@as(usize, 1), plan.keep.len);
    try std.testing.expectEqualStrings("fresh", plan.keep[0].name);
}
