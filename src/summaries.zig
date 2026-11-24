//! Fixed, newest-first calendar summaries; no storage or terminal dependencies.
const std = @import("std");
const timer = @import("root.zig");
const tz = timer.time_zone;

pub const Kind = enum { daily, weekly };
pub const Period = struct {
    interval: tz.Interval,
    first: tz.Date,
    last: tz.Date,
    totals: []timer.totals.Total,
    duration_ns: u128,
};

pub const Report = struct {
    allocator: std.mem.Allocator,
    periods: []Period,

    pub fn deinit(self: *Report) void {
        for (self.periods) |period| self.allocator.free(period.totals);
        self.allocator.free(self.periods);
        self.* = undefined;
    }
};

/// Includes the current period plus six days or three Monday–Sunday weeks.
/// Owns slices only; activity identities remain borrowed from sessions/live.
pub fn calculate(allocator: std.mem.Allocator, zone: tz.Zone, sessions: []const timer.Session, live: timer.Timer, now: timer.Instant, kind: Kind) !Report {
    var at = std.math.cast(i64, @divFloor(now.utc_ns, std.time.ns_per_s)) orelse return error.TimestampOutOfRange;
    const periods = try allocator.alloc(Period, if (kind == .daily) 7 else 4);
    var initialized: usize = 0;
    errdefer {
        for (periods[0..initialized]) |period| allocator.free(period.totals);
        allocator.free(periods);
    }
    for (periods) |*period| {
        const day = try zone.dayAt(at);
        const interval: tz.Interval = if (kind == .weekly) try zone.weekAt(at) else .{ .start_utc_seconds = day.start_utc_seconds, .end_utc_seconds = day.end_utc_seconds };
        const first = (try zone.dayAt(interval.start_utc_seconds)).date;
        const last = (try zone.dayAt(interval.end_utc_seconds - 1)).date;
        const totals = try timer.totals.calculateInterval(allocator, sessions, live, now, interval);
        period.* = .{ .interval = interval, .first = first, .last = last, .totals = totals, .duration_ns = 0 };
        initialized += 1;
        for (totals) |total| period.duration_ns = std.math.add(u128, period.duration_ns, total.duration_ns) catch return error.TotalOverflow;
        // Probe the instant before the boundary, never subtract a nominal day/week.
        at = interval.start_utc_seconds - 1;
    }
    return .{ .allocator = allocator, .periods = periods };
}

test "fixed windows include current period, empty periods, and live split across Monday" {
    var zone = try tz.Zone.init(null);
    defer zone.deinit();
    const monday = 1704067200; // 2024-01-01
    const activity: timer.Activity = .{ .id = "removed", .name = "Historical" };
    const sessions = [_]timer.Session{.{ .activity = activity, .start_utc_ns = (monday - 1) * @as(i128, std.time.ns_per_s), .end_utc_ns = (monday + 2) * @as(i128, std.time.ns_per_s), .duration_ns = 10 }};
    const live: timer.Timer = .{ .running = .{ .activity = .{ .id = "removed", .name = "Renamed" }, .start = .{ .monotonic_ns = 0, .utc_ns = (monday - 1) * @as(i128, std.time.ns_per_s) } } };
    for ([_]Kind{ .daily, .weekly }) |kind| {
        var report = try calculate(std.testing.allocator, zone, &sessions, live, .{ .monotonic_ns = 10, .utc_ns = (monday + 2) * @as(i128, std.time.ns_per_s) }, kind);
        defer report.deinit();
        try std.testing.expectEqual(@as(usize, if (kind == .daily) 7 else 4), report.periods.len);
        try std.testing.expectEqual(@as(u128, 14), report.periods[0].duration_ns);
        try std.testing.expectEqual(@as(u128, 6), report.periods[1].duration_ns);
        try std.testing.expectEqualStrings("Historical", report.periods[0].totals[0].activity.name);
        for (report.periods[2..]) |period| try std.testing.expectEqual(@as(u128, 0), period.duration_ns);
        for (report.periods[1..], report.periods[0 .. report.periods.len - 1]) |older, newer|
            try std.testing.expectEqual(older.interval.end_utc_seconds, newer.interval.start_utc_seconds);
    }
}

test "calendar windows preserve DST and year boundaries" {
    var zone = try tz.Zone.init("America/Los_Angeles");
    defer zone.deinit();
    for ([_]struct { at: i64, hours: i64 }{ .{ .at = 1710097200, .hours = 23 }, .{ .at = 1730660400, .hours = 25 } }) |case| {
        for ([_]Kind{ .daily, .weekly }) |kind| {
            var report = try calculate(std.testing.allocator, zone, &.{}, .{}, .{ .monotonic_ns = 0, .utc_ns = @as(i128, case.at) * std.time.ns_per_s }, kind);
            defer report.deinit();
            const interval = report.periods[0].interval;
            try std.testing.expectEqual((case.hours + @as(i64, if (kind == .daily) 0 else 144)) * 3600, interval.end_utc_seconds - interval.start_utc_seconds);
            for (report.periods) |period| try std.testing.expectEqual(@as(usize, 0), period.totals.len);
        }
    }
    var report = try calculate(std.testing.allocator, zone, &.{}, .{}, .{ .monotonic_ns = 0, .utc_ns = 1735732800 * @as(i128, std.time.ns_per_s) }, .weekly);
    defer report.deinit();
    try std.testing.expectEqualDeep(tz.Date{ .year = 2024, .month = 12, .day = 30 }, report.periods[0].first);
    try std.testing.expectEqualDeep(tz.Date{ .year = 2025, .month = 1, .day = 5 }, report.periods[0].last);
    try std.testing.expectError(error.TimestampOutOfRange, calculate(std.testing.allocator, zone, &.{}, .{}, .{ .monotonic_ns = 0, .utc_ns = std.math.maxInt(i128) }, .daily));
}

test "summary windows are half open and retain backward-span start attribution" {
    var zone = try tz.Zone.init(null);
    defer zone.deinit();
    const now: timer.Instant = .{ .monotonic_ns = 0, .utc_ns = 1704067200 * @as(i128, std.time.ns_per_s) };
    for ([_]Kind{ .daily, .weekly }) |kind| {
        var empty = try calculate(std.testing.allocator, zone, &.{}, .{}, now, kind);
        defer empty.deinit();
        const earliest = empty.periods[empty.periods.len - 1].interval.start_utc_seconds;
        const future = empty.periods[0].interval.end_utc_seconds;
        var sessions: [4]timer.Session = undefined;
        for (&sessions, [_]i64{ earliest, earliest - 1, future, 1704067300 }, [_]u64{ 5, 99, 99, 7 }) |*session, at, ns| {
            session.* = .{ .activity = .{ .id = "old", .name = "Removed" }, .start_utc_ns = @as(i128, at) * std.time.ns_per_s, .end_utc_ns = @as(i128, at) * std.time.ns_per_s, .duration_ns = ns };
        }
        sessions[3].end_utc_ns = now.utc_ns - 100;
        var report = try calculate(std.testing.allocator, zone, &sessions, .{}, now, kind);
        defer report.deinit();
        try std.testing.expectEqual(@as(u128, 7), report.periods[0].duration_ns);
        try std.testing.expectEqual(@as(u128, 5), report.periods[report.periods.len - 1].duration_ns);
    }
}
