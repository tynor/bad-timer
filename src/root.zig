//! In-memory timer state. Callers supply clock readings and retain completed sessions.
const std = @import("std");
pub const time_zone = @import("time_zone.zig");
pub const config = @import("config.zig");
pub const clock = @import("clock.zig");
pub const history = @import("history.zig");

test {
    _ = time_zone;
    _ = config;
    _ = clock;
    _ = history;
}

/// Strings are borrowed and must remain valid and unchanged while used by a timer or session.
pub const Activity = struct {
    id: []const u8,
    name: []const u8,
};

/// UTC is reporting metadata; only monotonic time determines elapsed duration.
pub const Instant = struct {
    monotonic_ns: u64,
    utc_ns: i128,
};

pub const Running = struct {
    activity: Activity,
    start: Instant,
};

pub const Session = struct {
    activity: Activity,
    start_utc_ns: i128,
    end_utc_ns: i128,
    duration_ns: u64,
};

pub const Timer = struct {
    running: ?Running = null,

    pub fn elapsed(self: Timer, now: Instant) error{MonotonicClockRegressed}!u64 {
        const running = self.running orelse return 0;
        if (now.monotonic_ns < running.start.monotonic_ns) return error.MonotonicClockRegressed;
        return now.monotonic_ns - running.start.monotonic_ns;
    }

    /// Selecting the same stable ID stops; selecting another switches at one instant.
    /// Returns the completed session, if any. No history is stored internally.
    pub fn select(self: *Timer, activity: Activity, now: Instant) error{MonotonicClockRegressed}!?Session {
        const same = if (self.running) |running| std.mem.eql(u8, running.activity.id, activity.id) else false;
        const completed = try self.stop(now);
        if (!same) self.running = .{ .activity = activity, .start = now };
        return completed;
    }

    pub fn stop(self: *Timer, now: Instant) error{MonotonicClockRegressed}!?Session {
        const running = self.running orelse return null;
        const duration = try self.elapsed(now);
        const completed: Session = .{
            .activity = running.activity,
            .start_utc_ns = running.start.utc_ns,
            .end_utc_ns = now.utc_ns,
            .duration_ns = duration,
        };
        self.running = null;
        return completed;
    }
};

const work: Activity = .{ .id = "work", .name = "Work" };
const rest: Activity = .{ .id = "rest", .name = "Rest" };

fn instant(monotonic_ns: u64, utc_ns: i128) Instant {
    return .{ .monotonic_ns = monotonic_ns, .utc_ns = utc_ns };
}

test "stopped timer, start, elapsed, and explicit stop" {
    var timer: Timer = .{};
    try std.testing.expectEqual(@as(u64, 0), try timer.elapsed(instant(0, 100)));
    try std.testing.expectEqual(null, try timer.stop(instant(0, 100)));
    try std.testing.expectEqual(null, try timer.select(work, instant(10, 100)));
    try std.testing.expectEqualDeep(work, timer.running.?.activity);
    try std.testing.expectEqual(@as(u64, 15), try timer.elapsed(instant(25, 115)));
    const session = (try timer.stop(instant(30, 120))).?;
    try std.testing.expectEqualDeep(Session{
        .activity = work,
        .start_utc_ns = 100,
        .end_utc_ns = 120,
        .duration_ns = 20,
    }, session);
    try std.testing.expectEqual(null, timer.running);
    try std.testing.expectEqual(null, try timer.stop(instant(40, 130)));
}

test "same stable ID stops and retains the original activity name" {
    var timer: Timer = .{};
    _ = try timer.select(work, instant(10, 100));
    const renamed: Activity = .{ .id = "work", .name = "Renamed" };
    const session = (try timer.select(renamed, instant(20, 110))).?;
    try std.testing.expectEqualDeep(work, session.activity);
    try std.testing.expectEqual(@as(u64, 10), session.duration_ns);
    try std.testing.expectEqual(null, timer.running);
}

test "switch closes the old session and starts exactly one at the same instant" {
    var timer: Timer = .{};
    _ = try timer.select(work, instant(10, 100));
    const boundary = instant(25, 115);
    const first = (try timer.select(rest, boundary)).?;
    try std.testing.expectEqualDeep(work, first.activity);
    try std.testing.expectEqual(@as(u64, 15), first.duration_ns);
    try std.testing.expectEqualDeep(Running{ .activity = rest, .start = boundary }, timer.running.?);
    try std.testing.expectEqual(first.end_utc_ns, timer.running.?.start.utc_ns);
    try std.testing.expectEqual(@as(u64, 0), try timer.elapsed(boundary));
    const second = (try timer.stop(instant(40, 130))).?;
    try std.testing.expectEqual(@as(u64, 30), first.duration_ns + second.duration_ns);
    try std.testing.expectEqual(null, timer.running);
}

test "wall clock jumps do not alter elapsed duration or recorded UTC readings" {
    for ([_]i128{ -500, 10000 }) |end_utc| {
        var timer: Timer = .{};
        _ = try timer.select(work, instant(10, 100));
        try std.testing.expectEqual(@as(u64, 20), try timer.elapsed(instant(30, end_utc)));
        const session = (try timer.stop(instant(30, end_utc))).?;
        try std.testing.expectEqual(@as(u64, 20), session.duration_ns);
        try std.testing.expectEqual(@as(i128, 100), session.start_utc_ns);
        try std.testing.expectEqual(end_utc, session.end_utc_ns);
    }
}

test "equal clock readings allow a zero duration session" {
    var timer: Timer = .{};
    const now = instant(10, 100);
    _ = try timer.select(work, now);
    const session = (try timer.select(work, now)).?;
    try std.testing.expectEqual(@as(u64, 0), session.duration_ns);
    try std.testing.expectEqual(null, timer.running);
}

test "monotonic readings before the start are rejected without changing state" {
    var timer: Timer = .{};
    _ = try timer.select(work, instant(10, 100));
    const before = timer;
    const invalid = instant(9, 200);
    try std.testing.expectError(error.MonotonicClockRegressed, timer.elapsed(invalid));
    try std.testing.expectError(error.MonotonicClockRegressed, timer.stop(invalid));
    try std.testing.expectEqualDeep(before, timer);
    try std.testing.expectError(error.MonotonicClockRegressed, timer.select(work, invalid));
    try std.testing.expectEqualDeep(before, timer);
    try std.testing.expectError(error.MonotonicClockRegressed, timer.select(rest, invalid));
    try std.testing.expectEqualDeep(before, timer);
    try std.testing.expectEqual(@as(u64, 5), (try timer.stop(instant(15, 205))).?.duration_ns);
}
