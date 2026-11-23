//! macOS calendar conversion; timestamps and day boundaries are Unix UTC seconds.
const std = @import("std");
const c = @import("time_zone_c");
const epoch_offset = 978307200;

pub const Date = struct { year: i32, month: i32, day: i32 };
pub const Day = struct {
    date: Date,
    start_utc_seconds: i64,
    /// Exclusive end: a calendar day need not contain 86400 seconds.
    end_utc_seconds: i64,
};

/// Owns a CoreFoundation calendar; do not copy, and call deinit exactly once.
pub const Zone = struct {
    calendar: c.CFCalendarRef,

    /// Omitted names use UTC. Only exact system IANA identifiers are accepted.
    pub fn init(name: ?[]const u8) !Zone {
        const bytes = name orelse "UTC";
        if (bytes.len == 0 or bytes.len > 1024 or std.mem.indexOfScalar(u8, bytes, 0) != null)
            return error.InvalidTimeZone;
        const text = c.CFStringCreateWithBytes(null, bytes.ptr, @intCast(bytes.len), c.kCFStringEncodingUTF8, 0) orelse
            return error.InvalidTimeZone;
        defer c.CFRelease(text);
        const names = c.CFTimeZoneCopyKnownNames() orelse return error.OutOfMemory;
        defer c.CFRelease(names);
        const range = c.CFRange{ .location = 0, .length = c.CFArrayGetCount(names) };
        // UTC is the default even on systems whose known-name list omits it.
        if (!std.mem.eql(u8, bytes, "UTC") and c.CFArrayContainsValue(names, range, text) == 0)
            return error.InvalidTimeZone;
        const zone = c.CFTimeZoneCreateWithName(null, text, 0) orelse return error.InvalidTimeZone;
        defer c.CFRelease(zone);
        const calendar = c.CFCalendarCreateWithIdentifier(null, c.kCFGregorianCalendar) orelse return error.OutOfMemory;
        c.CFCalendarSetTimeZone(calendar, zone);
        return .{ .calendar = calendar };
    }

    pub fn deinit(self: *Zone) void {
        c.CFRelease(self.calendar);
        self.* = undefined;
    }

    /// Returns the local date and containing day's UTC interval, without changing TZ.
    pub fn dayAt(self: Zone, utc_seconds: i64) !Day {
        // Keep integer seconds exact in CFAbsoluteTime and dates within years 1–9999.
        if (utc_seconds < -62135510400 or utc_seconds > 253402214399)
            return error.TimestampOutOfRange;
        const at: f64 = @floatFromInt(utc_seconds - epoch_offset);
        var date: Date = undefined;
        if (c.CFCalendarDecomposeAbsoluteTime(self.calendar, at, "yMd", &date.year, &date.month, &date.day) == 0)
            return error.CalendarConversionFailed;
        var start: f64 = undefined;
        var duration: f64 = undefined;
        if (c.CFCalendarGetTimeRangeOfUnit(self.calendar, c.kCFCalendarUnitDay, at, &start, &duration) == 0)
            return error.CalendarConversionFailed;
        return .{
            .date = date,
            .start_utc_seconds = @as(i64, @intFromFloat(start)) + epoch_offset,
            .end_utc_seconds = @as(i64, @intFromFloat(start + duration)) + epoch_offset,
        };
    }
};

test "zone validation and UTC default" {
    for ([_][]const u8{ "", "Not/A_Zone", "GMT+123", "America/Los_Angeles\x00junk", "\xff" }) |name| {
        try std.testing.expectError(error.InvalidTimeZone, Zone.init(name));
    }
    var zone = try Zone.init(null);
    defer zone.deinit();
    try std.testing.expectEqualDeep(Day{
        .date = .{ .year = 1970, .month = 1, .day = 1 },
        .start_utc_seconds = 0,
        .end_utc_seconds = 86400,
    }, try zone.dayAt(0));
    try std.testing.expectEqual(@as(i64, -86400), (try zone.dayAt(-1)).start_utc_seconds);
    try std.testing.expectError(error.TimestampOutOfRange, zone.dayAt(std.math.maxInt(i64)));
    try std.testing.expectError(error.TimestampOutOfRange, zone.dayAt(std.math.minInt(i64)));
}

test "Los Angeles local midnight and daylight saving day lengths" {
    var zone = try Zone.init("America/Los_Angeles");
    defer zone.deinit();
    const cases = [_]struct { at: i64, date: Date, start: i64, end: i64 }{
        .{ .at = 1710097200, .date = .{ .year = 2024, .month = 3, .day = 10 }, .start = 1710057600, .end = 1710140400 },
        .{ .at = 1730660400, .date = .{ .year = 2024, .month = 11, .day = 3 }, .start = 1730617200, .end = 1730707200 },
    };
    for (cases) |case| {
        const expected = Day{ .date = case.date, .start_utc_seconds = case.start, .end_utc_seconds = case.end };
        try std.testing.expectEqualDeep(expected, try zone.dayAt(case.at));
        try std.testing.expectEqualDeep(expected, try zone.dayAt(case.start));
        try std.testing.expectEqualDeep(expected, try zone.dayAt(case.end - 1));
        try std.testing.expectEqual(case.start, (try zone.dayAt(case.start - 1)).end_utc_seconds);
        try std.testing.expectEqual(case.end, (try zone.dayAt(case.end)).start_utc_seconds);
    }
    // A second calendar must not inherit or change the first calendar's zone.
    var utc = try Zone.init("UTC");
    defer utc.deinit();
    try std.testing.expectEqual(@as(i32, 31), (try zone.dayAt(1704067200)).date.day);
    try std.testing.expectEqual(@as(i32, 1), (try utc.dayAt(1704067200)).date.day);
}
