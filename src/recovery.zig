//! Explicit UTC recovery input; elapsed time is inferred, never measured.
const std = @import("std");

fn leap(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

pub const Result = struct { end_ns: i128, duration_ns: u64 };

/// Go time.ParseDuration semantics, with negative results rejected for recovery.
pub fn duration(text: []const u8, start_ns: i128) !Result {
    var s = text;
    const negative = s.len > 0 and s[0] == '-';
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) s = s[1..];
    var total: u64 = 0;
    if (std.mem.eql(u8, s, "0")) s = "" else if (s.len == 0) return error.InvalidDuration;
    while (s.len > 0) {
        var i: usize = 0;
        var whole: u64 = 0;
        const limit: u64 = 1 << 63;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
            if (whole > limit / 10) return error.InvalidDuration;
            whole = whole * 10 + s[i] - '0';
            if (whole > limit) return error.InvalidDuration;
        }
        const pre = i > 0;
        var fraction: u64 = 0;
        var scale: f64 = 1;
        var post = false;
        if (i < s.len and s[i] == '.') {
            i += 1;
            var overflow = false;
            while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
                post = true;
                if (overflow) continue;
                if (fraction > (limit - 1) / 10) {
                    overflow = true;
                    continue;
                }
                const next = fraction * 10 + s[i] - '0';
                if (next > limit) {
                    overflow = true;
                    continue;
                }
                fraction = next;
                scale *= 10;
            }
        }
        if (!pre and !post) return error.InvalidDuration;
        const unit_start = i;
        while (i < s.len and s[i] != '.' and !std.ascii.isDigit(s[i])) : (i += 1) {}
        const name = s[unit_start..i];
        const unit: u64 = if (std.mem.eql(u8, name, "ns")) 1 else if (std.mem.eql(u8, name, "us") or std.mem.eql(u8, name, "µs") or std.mem.eql(u8, name, "μs")) 1000 else if (std.mem.eql(u8, name, "ms")) 1000000 else if (std.mem.eql(u8, name, "s")) 1000000000 else if (std.mem.eql(u8, name, "m")) 60000000000 else if (std.mem.eql(u8, name, "h")) 3600000000000 else return error.InvalidDuration;
        if (whole > limit / unit) return error.InvalidDuration;
        var value = whole * unit;
        // Match Go's float64 fraction conversion, including sub-nanosecond truncation.
        if (fraction > 0) value += @intFromFloat(@as(f64, @floatFromInt(fraction)) * (@as(f64, @floatFromInt(unit)) / scale));
        if (value > limit or total > limit - value) return error.InvalidDuration;
        total += value;
        s = s[i..];
    }
    if (negative and total != 0) return error.NegativeDuration;
    if (total > std.math.maxInt(i64)) return error.InvalidDuration;
    return .{ .end_ns = std.math.add(i128, start_ns, total) catch return error.DurationOutOfRange, .duration_ns = total };
}

/// Strict whole-second UTC ISO-8601, years 0001–9999.
pub fn endTime(text: []const u8, start_ns: i128) !Result {
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
    const elapsed = std.math.sub(i128, end_ns, start_ns) catch return error.DurationOutOfRange;
    if (elapsed < 0) return error.EndBeforeStart;
    return .{ .end_ns = end_ns, .duration_ns = std.math.cast(u64, elapsed) orelse return error.DurationOutOfRange };
}

test "Go-generated duration compatibility cases" {
    const Case = struct { text: []const u8, nanoseconds: ?u64 };
    const cases = try std.json.parseFromSlice([]Case, std.testing.allocator, @embedFile("duration_cases.json"), .{});
    defer cases.deinit();
    for (cases.value) |case| {
        const actual = duration(case.text, 100) catch {
            try std.testing.expect(case.nanoseconds == null);
            continue;
        };
        try std.testing.expect(case.nanoseconds != null);
        try std.testing.expectEqual(case.nanoseconds.?, actual.duration_ns);
        try std.testing.expectEqual(@as(i128, 100) + case.nanoseconds.?, actual.end_ns);
    }
    try std.testing.expectError(error.DurationOutOfRange, duration("1ns", std.math.maxInt(i128)));
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
