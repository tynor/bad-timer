//! Display-only native rows; all attribution stays in the shared totals calculator.
const std = @import("std");
const core = @import("root.zig");
const Row = struct { name: []const u8, index: ?usize, today: []const u8, week: []const u8 };
fn duration(allocator: std.mem.Allocator, ns: u128) ![]const u8 {
    const s = ns / std.time.ns_per_s;
    return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ s / 3600, s / 60 % 60, s % 60 });
}
fn amount(items: []const core.totals.Total, id: []const u8) u128 {
    for (items) |item| if (std.mem.eql(u8, item.activity.id, id)) return item.duration_ns;
    return 0;
}
pub fn snapshot(allocator: std.mem.Allocator, config: core.config.Config, zone: core.time_zone.Zone, sessions: []const core.Session, live: core.Timer, now: core.Instant) ![:0]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const today = try core.totals.calculate(a, zone, sessions, live, now);
    const week = try core.totals.calculateWeek(a, zone, sessions, live, now);
    var rows: std.ArrayList(Row) = .empty;
    var seen = std.StringHashMap(void).init(a);
    for (config.activities(), 0..) |activity, index| {
        try seen.put(activity.id, {});
        try rows.append(a, .{ .name = activity.name, .index = index, .today = try duration(a, amount(today, activity.id)), .week = try duration(a, amount(week, activity.id)) });
    }
    // Include week-only removed IDs as well as those with time today.
    for ([_][]const core.totals.Total{ today, week }) |items| {
        for (items) |item| {
            if (seen.contains(item.activity.id)) continue;
            try seen.put(item.activity.id, {});
            try rows.append(a, .{ .name = item.activity.name, .index = null, .today = try duration(a, amount(today, item.activity.id)), .week = try duration(a, amount(week, item.activity.id)) });
        }
    }
    const json = try std.json.Stringify.valueAlloc(a, .{ .zone = config.timeZone(), .rows = rows.items }, .{});
    return allocator.dupeSentinel(u8, json, 0);
}

test "native rows preserve configured names, removed week-only time, live time and Monday rollover" {
    const a = std.testing.allocator;
    var config = try core.config.Config.parse(a, "{\"time_zone\":\"UTC\",\"activities\":[{\"id\":\"work\",\"name\":\"Renamed\"}]}");
    defer config.deinit();
    var zone = try core.time_zone.Zone.init("UTC");
    defer zone.deinit();
    const ns = std.time.ns_per_s;
    const sessions = [_]core.Session{
        .{ .activity = .{ .id = "removed", .name = "Historical" }, .start_utc_ns = 0, .end_utc_ns = ns, .duration_ns = 5 * ns, .time_zone = "UTC" },
    };
    const live: core.Timer = .{ .running = .{ .activity = .{ .id = "work", .name = "Old name" }, .start = .{ .utc_ns = 86400 * ns, .monotonic_ns = 0 }, .time_zone = "UTC" } };
    const json = try snapshot(a, config, zone, &sessions, live, .{ .utc_ns = 86401 * ns, .monotonic_ns = ns });
    defer a.free(json);
    const parsed = try std.json.parseFromSlice(struct { zone: []const u8, rows: []Row }, a, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Renamed", parsed.value.rows[0].name);
    try std.testing.expectEqualStrings("00:00:01", parsed.value.rows[0].today);
    try std.testing.expectEqualStrings("Historical", parsed.value.rows[1].name);
    try std.testing.expect(parsed.value.rows[1].index == null);
    try std.testing.expectEqualStrings("00:00:00", parsed.value.rows[1].today);
    try std.testing.expectEqualStrings("00:00:05", parsed.value.rows[1].week);
    const monday = try snapshot(a, config, zone, &sessions, .{}, .{ .utc_ns = 4 * 86400 * ns, .monotonic_ns = 0 });
    defer a.free(monday);
    try std.testing.expect(std.mem.indexOf(u8, monday, "Historical") == null);
}
