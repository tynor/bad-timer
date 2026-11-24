//! Calendar-day/week attribution of measured duration, never UTC-derived elapsed time.
const std = @import("std");
const timer = @import("root.zig");
const tz = @import("time_zone.zig");
const ns_per_second = 1_000_000_000;

pub const Total = struct {
    /// Borrowed identity from the first contributing session (or the live timer).
    activity: timer.Activity,
    duration_ns: u128,
};

/// Caller frees the result; activity strings remain borrowed from the inputs.
/// Returns only activities with nonzero time, in first-contribution order.
/// `now` selects the local day and supplies the live timer's current reading.
pub fn calculate(allocator: std.mem.Allocator, zone: tz.Zone, sessions: []const timer.Session, live: timer.Timer, now: timer.Instant) ![]Total {
    const seconds = std.math.cast(i64, @divFloor(now.utc_ns, ns_per_second)) orelse return error.TimestampOutOfRange;
    const day = try zone.dayAt(seconds);
    return calculateDates(allocator, zone, sessions, live, now, .{ .first = day.date, .end = (try zone.dayAt(day.end_utc_seconds)).date });
}

/// Same ownership/attribution as calculate, for the current Monday–Sunday week.
pub fn calculateWeek(allocator: std.mem.Allocator, zone: tz.Zone, sessions: []const timer.Session, live: timer.Timer, now: timer.Instant) ![]Total {
    const seconds = std.math.cast(i64, @divFloor(now.utc_ns, ns_per_second)) orelse return error.TimestampOutOfRange;
    const week = try zone.weekAt(seconds);
    return calculateDates(allocator, zone, sessions, live, now, .{ .first = (try zone.dayAt(week.start_utc_seconds)).date, .end = (try zone.dayAt(week.end_utc_seconds)).date });
}

/// Same ownership rules, for a caller-selected half-open calendar interval.
pub fn calculateInterval(allocator: std.mem.Allocator, sessions: []const timer.Session, live: timer.Timer, now: timer.Instant, day: tz.Interval) ![]Total {
    if (day.end_utc_seconds <= day.start_utc_seconds) return error.InvalidInterval;
    return calculateFor(allocator, sessions, live, now, day, null);
}

pub const Dates = struct { first: tz.Date, end: tz.Date };

/// Shared date labels, interpreted in each session's saved zone. Unzoned inputs
/// use the supplied display zone; normal startup durably assigns legacy zones.
pub fn calculateDates(allocator: std.mem.Allocator, zone: tz.Zone, sessions: []const timer.Session, live: timer.Timer, now: timer.Instant, dates: Dates) ![]Total {
    return calculateFor(allocator, sessions, live, now, try zone.intervalForDates(dates.first, dates.end), dates);
}

fn calculateFor(allocator: std.mem.Allocator, sessions: []const timer.Session, live: timer.Timer, now: timer.Instant, day: tz.Interval, dates: ?Dates) ![]Total {
    var totals: std.ArrayList(Total) = .empty;
    errdefer totals.deinit(allocator);
    var intervals: std.StringHashMap(tz.Interval) = .init(allocator);
    defer intervals.deinit();
    for (sessions) |session| try add(allocator, &totals, session, try sessionInterval(&intervals, session.time_zone, day, dates));
    if (live.running) |running| {
        try add(allocator, &totals, .{
            .activity = running.activity,
            .start_utc_ns = running.start.utc_ns,
            .end_utc_ns = now.utc_ns,
            .duration_ns = try live.elapsed(now),
            .time_zone = running.time_zone,
        }, try sessionInterval(&intervals, running.time_zone, day, dates));
    }
    return totals.toOwnedSlice(allocator);
}

fn sessionInterval(cache: *std.StringHashMap(tz.Interval), name: ?[]const u8, fallback: tz.Interval, dates: ?Dates) !tz.Interval {
    const labels = dates orelse return fallback;
    const saved = name orelse return fallback;
    if (cache.get(saved)) |interval| return interval;
    var zone = try tz.Zone.init(saved);
    defer zone.deinit();
    const interval = try zone.intervalForDates(labels.first, labels.end);
    try cache.put(saved, interval);
    return interval;
}

fn add(allocator: std.mem.Allocator, totals: *std.ArrayList(Total), session: timer.Session, day: anytype) !void {
    const duration = share(session, day);
    if (duration == 0) return;
    for (totals.items) |*total| {
        if (std.mem.eql(u8, total.activity.id, session.activity.id)) {
            total.duration_ns = std.math.add(u128, total.duration_ns, duration) catch return error.TotalOverflow;
            return;
        }
    }
    try totals.append(allocator, .{ .activity = session.activity, .duration_ns = duration });
}

fn share(session: timer.Session, day: anytype) u64 {
    const start: i256 = session.start_utc_ns;
    const end: i256 = session.end_utc_ns;
    const day_start: i256 = @as(i128, day.start_utc_seconds) * ns_per_second;
    const day_end: i256 = @as(i128, day.end_utc_seconds) * ns_per_second;
    if (end <= start) return if (start >= day_start and start < day_end) session.duration_ns else 0;
    const lower = @max(start, day_start);
    const upper = @min(end, day_end);
    if (lower >= upper) return 0;
    const span: u256 = @intCast(end - start);
    // Cumulative rounding conserves every nanosecond across adjacent days.
    const before = @as(u256, @intCast(lower - start)) * session.duration_ns / span;
    const through = @as(u256, @intCast(upper - start)) * session.duration_ns / span;
    return @intCast(through - before);
}

const work: timer.Activity = .{ .id = "work", .name = "Old work" };
fn fixture(activity: timer.Activity, start: i64, end: i64, duration: u64) timer.Session {
    return .{ .activity = activity, .start_utc_ns = @as(i128, start) * ns_per_second, .end_utc_ns = @as(i128, end) * ns_per_second, .duration_ns = duration };
}

test "shared day and week labels use saved zones, group IDs, and retain live zones" {
    var display = try tz.Zone.init("UTC");
    defer display.deinit();
    var west = fixture(work, 1704178800, 1704178800, 7); // Jan 2 UTC, Jan 1 Los Angeles.
    west.time_zone = "America/Los_Angeles";
    var east = fixture(.{ .id = "work", .name = "Renamed" }, 1704038400, 1704038400, 11); // Dec 31 UTC, Jan 1 Tokyo.
    east.time_zone = "Asia/Tokyo";
    var excluded = fixture(.{ .id = "removed", .name = "Removed" }, 1704038400, 1704038400, 99);
    excluded.time_zone = "UTC";
    const now: timer.Instant = .{ .monotonic_ns = 5, .utc_ns = 1704110400 * @as(i128, ns_per_second) };
    var live: timer.Timer = .{ .running = .{ .activity = work, .start = .{ .monotonic_ns = 0, .utc_ns = now.utc_ns - 10 }, .time_zone = "Asia/Tokyo" } };
    const daily = try calculate(std.testing.allocator, display, &.{ west, east, excluded }, live, now);
    defer std.testing.allocator.free(daily);
    try std.testing.expectEqual(@as(usize, 1), daily.len);
    try std.testing.expectEqual(@as(u128, 23), daily[0].duration_ns);
    try std.testing.expectEqualStrings("Old work", daily[0].activity.name);
    const weekly = try calculateWeek(std.testing.allocator, display, &.{ west, east, excluded }, live, now);
    defer std.testing.allocator.free(weekly);
    try std.testing.expectEqual(@as(u128, 23), weekly[0].duration_ns);
    // The live span is Jan 1 UTC but Jan 2 in Tokyo: shared Jan 1 excludes it.
    live.running.?.start.utc_ns = 1704124800 * @as(i128, ns_per_second);
    const later: timer.Instant = .{ .monotonic_ns = 5, .utc_ns = live.running.?.start.utc_ns + ns_per_second };
    const outside = try calculate(std.testing.allocator, display, &.{}, live, later);
    defer std.testing.allocator.free(outside);
    try std.testing.expectEqual(@as(usize, 0), outside.len);
    west.time_zone = "Invalid/Zone";
    try std.testing.expectError(error.InvalidTimeZone, calculate(std.testing.allocator, display, &.{west}, .{}, now));
}

test "mixed saved zones split measured spans across DST days and weeks" {
    var display = try tz.Zone.init("UTC");
    defer display.deinit();
    var la = try tz.Zone.init("America/Los_Angeles");
    defer la.deinit();
    for ([_]i64{ 1710072000, 1730635200 }) |at| {
        for ([_]bool{ false, true }) |weekly| {
            const local_day = try la.dayAt(at);
            const utc_day = try display.dayAt(at);
            const local: tz.Interval = if (weekly) try la.weekAt(at) else .{ .start_utc_seconds = local_day.start_utc_seconds, .end_utc_seconds = local_day.end_utc_seconds };
            const utc: tz.Interval = if (weekly) try display.weekAt(at) else .{ .start_utc_seconds = utc_day.start_utc_seconds, .end_utc_seconds = utc_day.end_utc_seconds };
            const local_seconds: u64 = @intCast(local.end_utc_seconds - local.start_utc_seconds);
            const utc_seconds: u64 = @intCast(utc.end_utc_seconds - utc.start_utc_seconds);
            var west = fixture(work, local.start_utc_seconds - 3600, local.end_utc_seconds + 3600, local_seconds + 7200);
            west.time_zone = "America/Los_Angeles";
            var neutral = fixture(work, utc.start_utc_seconds - 3600, utc.end_utc_seconds + 3600, utc_seconds + 7200);
            neutral.time_zone = "UTC";
            const now: timer.Instant = .{ .monotonic_ns = 0, .utc_ns = @as(i128, at) * ns_per_second };
            const result = if (weekly) try calculateWeek(std.testing.allocator, display, &.{ west, neutral }, .{}, now) else try calculate(std.testing.allocator, display, &.{ west, neutral }, .{}, now);
            defer std.testing.allocator.free(result);
            try std.testing.expectEqual(@as(u128, local_seconds) + utc_seconds, result[0].duration_ns);
            try std.testing.expect(local_seconds != utc_seconds);
        }
    }
}

test "same-day totals group stable IDs, retain removed activities, and include live time" {
    var zone = try tz.Zone.init(null);
    defer zone.deinit();
    const renamed: timer.Activity = .{ .id = "work", .name = "Renamed work" };
    const removed: timer.Activity = .{ .id = "removed", .name = "Removed" };
    const sessions = [_]timer.Session{ fixture(work, 1, 2, 10), fixture(renamed, 3, 4, 20), fixture(removed, 5, 6, 7) };
    const live: timer.Timer = .{ .running = .{ .activity = renamed, .start = .{ .monotonic_ns = 10, .utc_ns = 7 * ns_per_second } } };
    const result = try calculate(std.testing.allocator, zone, &sessions, live, .{ .monotonic_ns = 15, .utc_ns = 8 * ns_per_second });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(u128, 35), result[0].duration_ns);
    try std.testing.expectEqualStrings("Old work", result[0].activity.name);
    try std.testing.expectEqualStrings("removed", result[1].activity.id);
    try std.testing.expectEqual(@as(u128, 7), result[1].duration_ns);
    try std.testing.expectError(error.MonotonicClockRegressed, calculate(std.testing.allocator, zone, &sessions, live, .{ .monotonic_ns = 9, .utc_ns = 8 * ns_per_second }));
}

test "midnight splitting conserves nanoseconds and uses half-open days" {
    var zone = try tz.Zone.init(null);
    defer zone.deinit();
    const first = try zone.dayAt(0);
    const second = try zone.dayAt(86400);
    const crossing = fixture(work, 86399, 86402, 10);
    try std.testing.expectEqual(@as(u64, 3), share(crossing, first));
    try std.testing.expectEqual(@as(u64, 7), share(crossing, second));
    try std.testing.expectEqual(@as(u64, 10), share(fixture(work, 1, 86400, 10), first));
    try std.testing.expectEqual(@as(u64, 0), share(fixture(work, 1, 86400, 10), second));
    try std.testing.expectEqual(@as(u64, 0), share(fixture(work, 86400, 86401, 10), first));
    try std.testing.expectEqual(@as(u64, 0), share(fixture(work, 1, 2, 0), first));
}

test "DST day shares use actual 23 and 25 hour boundaries" {
    var zone = try tz.Zone.init("America/Los_Angeles");
    defer zone.deinit();
    for ([_]i64{ 1710097200, 1730660400 }) |at| {
        const day = try zone.dayAt(at);
        const seconds: u64 = @intCast(day.end_utc_seconds - day.start_utc_seconds);
        const spanning = fixture(work, day.start_utc_seconds - 3600, day.end_utc_seconds + 3600, seconds + 7200);
        try std.testing.expectEqual(seconds, share(spanning, day));
        try std.testing.expectEqual(@as(u64, 3600), share(spanning, try zone.dayAt(day.start_utc_seconds - 1)));
        try std.testing.expectEqual(@as(u64, 3600), share(spanning, try zone.dayAt(day.end_utc_seconds)));
    }
}

test "clock jumps retain measured time, backward and zero spans use start date" {
    var zone = try tz.Zone.init(null);
    defer zone.deinit();
    const day = try zone.dayAt(0);
    for ([_]i64{ -100, 100, 80000 }) |end| {
        try std.testing.expectEqual(@as(u64, 42), share(fixture(work, 100, end, 42), day));
    }
    const backward = fixture(work, 86400, -100, 42);
    try std.testing.expectEqual(@as(u64, 0), share(backward, day));
    try std.testing.expectEqual(@as(u64, 42), share(backward, try zone.dayAt(86400)));
    // Full-width persisted timestamps must not overflow intermediate arithmetic.
    const extreme: timer.Session = .{ .activity = work, .start_utc_ns = std.math.minInt(i128), .end_utc_ns = std.math.maxInt(i128), .duration_ns = std.math.maxInt(u64) };
    _ = share(extreme, day);
}

test "live session crosses midnight and pre-epoch fractional timestamps floor to prior day" {
    var zone = try tz.Zone.init(null);
    defer zone.deinit();
    const live: timer.Timer = .{ .running = .{ .activity = work, .start = .{ .monotonic_ns = 0, .utc_ns = 86399 * ns_per_second } } };
    const result = try calculate(std.testing.allocator, zone, &.{}, live, .{ .monotonic_ns = 10, .utc_ns = 86402 * ns_per_second });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(u128, 7), result[0].duration_ns);
    const tiny: timer.Session = .{ .activity = work, .start_utc_ns = -2, .end_utc_ns = 1, .duration_ns = 3 };
    const previous = try calculate(std.testing.allocator, zone, &.{tiny}, .{}, .{ .monotonic_ns = 0, .utc_ns = -1 });
    defer std.testing.allocator.free(previous);
    try std.testing.expectEqual(@as(u128, 2), previous[0].duration_ns);
}

test "weekly attribution groups renames, removed IDs, live time and boundary rounding" {
    var zone = try tz.Zone.init(null);
    defer zone.deinit();
    const week = try zone.weekAt(0);
    const start = week.start_utc_seconds;
    const renamed: timer.Activity = .{ .id = "work", .name = "New work" };
    const removed: timer.Activity = .{ .id = "removed", .name = "Removed" };
    const crossing = fixture(work, start - 1, start + 2, 10);
    const sessions = [_]timer.Session{
        crossing,
        fixture(renamed, 1, 2, 20),
        fixture(removed, 3, 4, 7),
        fixture(work, 100, -100, 42),
        fixture(work, week.end_utc_seconds, week.end_utc_seconds, 99),
    };
    const live: timer.Timer = .{ .running = .{ .activity = renamed, .start = .{ .monotonic_ns = 10, .utc_ns = 7 * ns_per_second } } };
    const now: timer.Instant = .{ .monotonic_ns = 15, .utc_ns = 8 * ns_per_second };
    const result = try calculateWeek(std.testing.allocator, zone, &sessions, live, now);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(@as(u128, 74), result[0].duration_ns);
    try std.testing.expectEqualStrings("Old work", result[0].activity.name);
    try std.testing.expectEqual(@as(u128, 7), result[1].duration_ns);
    try std.testing.expectEqual(@as(u64, 3), share(crossing, try zone.weekAt(start - 1)));
    try std.testing.expectError(error.MonotonicClockRegressed, calculateWeek(std.testing.allocator, zone, &sessions, live, .{ .monotonic_ns = 9, .utc_ns = now.utc_ns }));
    const empty = try calculateWeek(std.testing.allocator, zone, &.{}, .{}, now);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectError(error.TimestampOutOfRange, calculateWeek(std.testing.allocator, zone, &.{}, .{}, .{ .monotonic_ns = 0, .utc_ns = std.math.maxInt(i128) }));
}

test "weekly DST shares use calendar boundaries and include live Monday crossings" {
    var zone = try tz.Zone.init("America/Los_Angeles");
    defer zone.deinit();
    for ([_]i64{ 1710097200, 1730660400 }) |at| {
        const week = try zone.weekAt(at);
        const seconds: u64 = @intCast(week.end_utc_seconds - week.start_utc_seconds);
        try std.testing.expectEqual(seconds, share(fixture(work, week.start_utc_seconds - 3600, week.end_utc_seconds + 3600, seconds + 7200), week));
        const live: timer.Timer = .{ .running = .{ .activity = work, .start = .{ .monotonic_ns = 0, .utc_ns = @as(i128, week.end_utc_seconds - 1) * ns_per_second } } };
        const result = try calculateWeek(std.testing.allocator, zone, &.{}, live, .{ .monotonic_ns = 10, .utc_ns = @as(i128, week.end_utc_seconds + 2) * ns_per_second });
        defer std.testing.allocator.free(result);
        try std.testing.expectEqual(@as(u128, 7), result[0].duration_ns);
    }
}

test "empty history and invalid query dates" {
    try std.testing.expectError(error.InvalidInterval, calculateInterval(std.testing.allocator, &.{}, .{}, .{ .monotonic_ns = 0, .utc_ns = 0 }, .{ .start_utc_seconds = 1, .end_utc_seconds = 1 }));
    var zone = try tz.Zone.init(null);
    defer zone.deinit();
    const result = try calculate(std.testing.allocator, zone, &.{}, .{}, .{ .monotonic_ns = 0, .utc_ns = -1 });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
    try std.testing.expectError(error.TimestampOutOfRange, calculate(std.testing.allocator, zone, &.{}, .{}, .{ .monotonic_ns = 0, .utc_ns = std.math.maxInt(i128) }));
}
