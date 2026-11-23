//! macOS clock acquisition, separate from deterministic timer state.
const std = @import("std");
const c = @import("clock_c");
const Instant = @import("root.zig").Instant;

/// Reads are sequential, not atomic. UTC is reporting metadata, not elapsed time.
pub fn now() !Instant {
    // macOS documents RAW as unadjusted and suspend-inclusive, unlike UPTIME_RAW.
    const monotonic = try readClock(c.CLOCK_MONOTONIC_RAW);
    const utc = try readClock(c.CLOCK_REALTIME);
    return .{
        .monotonic_ns = std.math.cast(u64, monotonic) orelse return error.ClockReadingOutOfRange,
        .utc_ns = utc,
    };
}

fn readClock(id: c.clockid_t) !i128 {
    var reading: c.struct_timespec = undefined;
    if (c.clock_gettime(id, &reading) != 0) return error.ClockReadFailed;
    return nanoseconds(reading);
}

fn nanoseconds(reading: c.struct_timespec) !i128 {
    if (reading.tv_nsec < 0 or reading.tv_nsec >= std.time.ns_per_s)
        return error.ClockReadingOutOfRange;
    return @as(i128, reading.tv_sec) * std.time.ns_per_s + reading.tv_nsec;
}

test "timespec conversion preserves nanoseconds and pre-epoch UTC" {
    try std.testing.expectEqual(@as(i128, 1234567890123456789), try nanoseconds(.{ .tv_sec = 1234567890, .tv_nsec = 123456789 }));
    try std.testing.expectEqual(@as(i128, -1), try nanoseconds(.{ .tv_sec = -1, .tv_nsec = 999999999 }));
    try std.testing.expectEqual(@as(i128, 0), try nanoseconds(.{ .tv_sec = 0, .tv_nsec = 0 }));
    try std.testing.expectError(error.ClockReadingOutOfRange, nanoseconds(.{ .tv_sec = 0, .tv_nsec = -1 }));
    try std.testing.expectError(error.ClockReadingOutOfRange, nanoseconds(.{ .tv_sec = 0, .tv_nsec = 1000000000 }));
}

test "invalid clock surfaces an OS read failure" {
    try std.testing.expectError(error.ClockReadFailed, readClock(std.math.maxInt(c.clockid_t)));
}

test "live clock readings drive the timer" {
    const Timer = @import("root.zig").Timer;
    var timer: Timer = .{};
    const start = try now();
    _ = try timer.select(.{ .id = "work", .name = "Work" }, start);
    const end = try now();
    try std.testing.expect(end.monotonic_ns >= start.monotonic_ns);
    const session = (try timer.stop(end)).?;
    try std.testing.expectEqual(end.monotonic_ns - start.monotonic_ns, session.duration_ns);
    try std.testing.expectEqual(start.utc_ns, session.start_utc_ns);
    try std.testing.expectEqual(end.utc_ns, session.end_utc_ns);
}
