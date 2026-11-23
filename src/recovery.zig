//! Explicit UTC recovery input; elapsed time is inferred, never measured.
const std = @import("std");

fn leap(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

/// Strict whole-second UTC ISO-8601, years 0001–9999.
pub fn endTime(text: []const u8, start_ns: i128) !struct { end_ns: i128, duration_ns: u64 } {
    if (text.len != 20) return error.InvalidTimestamp;
    for (text, 0..) |byte, i| {
        const separator: ?u8 = switch (i) {
            4, 7 => '-',
            10 => 'T',
            13, 16 => ':',
            19 => 'Z',
            else => null,
        };
        if (separator) |s| {
            if (byte != s) return error.InvalidTimestamp;
        } else if (!std.ascii.isDigit(byte)) return error.InvalidTimestamp;
    }
    const year = try std.fmt.parseInt(i64, text[0..4], 10);
    const month = try std.fmt.parseInt(usize, text[5..7], 10);
    const day = try std.fmt.parseInt(i64, text[8..10], 10);
    const hour = try std.fmt.parseInt(i64, text[11..13], 10);
    const minute = try std.fmt.parseInt(i64, text[14..16], 10);
    const second = try std.fmt.parseInt(i64, text[17..19], 10);
    if (year == 0 or month == 0 or month > 12 or hour > 23 or minute > 59 or second > 59) return error.InvalidTimestamp;
    var months = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (leap(year)) months[1] = 29;
    if (day == 0 or day > months[month - 1]) return error.InvalidTimestamp;
    const y = year - 1;
    var days = 365 * y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400) - 719162;
    for (months[0 .. month - 1]) |length| days += length;
    days += day - 1;
    const end_ns = @as(i128, days * 86400 + hour * 3600 + minute * 60 + second) * std.time.ns_per_s;
    const duration = std.math.sub(i128, end_ns, start_ns) catch return error.DurationOutOfRange;
    if (duration < 0) return error.EndBeforeStart;
    return .{ .end_ns = end_ns, .duration_ns = std.math.cast(u64, duration) orelse return error.DurationOutOfRange };
}

test "strict UTC recovery and bounded inferred duration" {
    const t = std.testing;
    try t.expectEqual(@as(i128, 0), (try endTime("1970-01-01T00:00:00Z", 0)).end_ns);
    try t.expectEqual(@as(u64, 999999900), (try endTime("1970-01-01T00:00:01Z", 100)).duration_ns);
    try t.expectEqual(@as(i128, -1000000000), (try endTime("1969-12-31T23:59:59Z", -1000000000)).end_ns);
    _ = try endTime("2000-02-29T12:00:00Z", 951782400000000000);
    for ([_][]const u8{ "1900-02-29T00:00:00Z", "2024-04-31T00:00:00Z", "0000-01-01T00:00:00Z", "2024-01-01T24:00:00Z", "2024-01-01T00:00:60Z", "2024-01-01 00:00:00Z", "2024-01-01T00:00:00+00:00" }) |text| try t.expectError(error.InvalidTimestamp, endTime(text, 0));
    try t.expectError(error.EndBeforeStart, endTime("1970-01-01T00:00:00Z", 1));
    try t.expectError(error.DurationOutOfRange, endTime("9999-01-01T00:00:00Z", 0));
    try t.expectError(error.DurationOutOfRange, endTime("1970-01-01T00:00:00Z", std.math.minInt(i128)));
}
