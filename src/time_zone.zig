//! macOS calendar conversion; timestamps and day boundaries are Unix UTC seconds.
const std = @import("std");
const c = @import("time_zone_c");
const epoch_offset = 978307200;

pub const Interval = struct { start_utc_seconds: i64, end_utc_seconds: i64 };

pub const Date = struct { year: i32, month: i32, day: i32 };
pub const Day = struct {
    date: Date,
    start_utc_seconds: i64,
    /// Exclusive end: a calendar day need not contain 86400 seconds.
    end_utc_seconds: i64,
};

/// Owned UTF-8 system identifier, or UTC if unavailable/unsupported. Caller frees.
pub fn systemName(allocator: std.mem.Allocator) ![]const u8 {
    const zone = c.CFTimeZoneCopySystem();
    defer if (zone != null) c.CFRelease(zone);
    return systemNameFrom(allocator, zone);
}

fn systemNameFrom(allocator: std.mem.Allocator, zone: c.CFTimeZoneRef) ![]const u8 {
    if (zone) |value| {
        var buffer: [1025]u8 = undefined;
        if (c.CFStringGetCString(c.CFTimeZoneGetName(value), &buffer, buffer.len, c.kCFStringEncodingUTF8) != 0) {
            const name = std.mem.sliceTo(&buffer, 0);
            if (Zone.init(name)) |resolved| {
                var validated = resolved;
                defer validated.deinit();
                return allocator.dupe(u8, name);
            } else |err| switch (err) {
                error.InvalidTimeZone => {},
                else => return err,
            }
        }
    }
    return allocator.dupe(u8, "UTC");
}

/// Owns a CoreFoundation calendar; do not copy, and call deinit exactly once.
pub const Zone = struct {
    calendar: c.CFCalendarRef,

    /// Null explicitly selects UTC; app defaults resolve systemName first.
    /// Only exact system IANA identifiers are accepted.
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
        c.CFCalendarSetFirstWeekday(calendar, 2); // Monday, independent of locale.
        return .{ .calendar = calendar };
    }

    pub fn deinit(self: *Zone) void {
        c.CFRelease(self.calendar);
        self.* = undefined;
    }

    /// Monday through next Monday in the configured zone, including DST changes.
    pub fn weekAt(self: Zone, utc_seconds: i64) !Interval {
        _ = try self.dayAt(utc_seconds);
        const at: f64 = @floatFromInt(utc_seconds - epoch_offset);
        var start: f64 = undefined;
        var duration: f64 = undefined;
        if (c.CFCalendarGetTimeRangeOfUnit(self.calendar, c.kCFCalendarUnitWeekOfYear, at, &start, &duration) == 0)
            return error.CalendarConversionFailed;
        return .{
            .start_utc_seconds = @as(i64, @intFromFloat(start)) + epoch_offset,
            .end_utc_seconds = @as(i64, @intFromFloat(start + duration)) + epoch_offset,
        };
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

test "system identifier resolution and UTC fallback" {
    const allocator = std.testing.allocator;
    const missing = try systemNameFrom(allocator, null);
    defer allocator.free(missing);
    try std.testing.expectEqualStrings("UTC", missing);
    const text = c.CFStringCreateWithCString(null, "America/Los_Angeles", c.kCFStringEncodingUTF8) orelse return error.OutOfMemory;
    defer c.CFRelease(text);
    const zone = c.CFTimeZoneCreateWithName(null, text, 0) orelse return error.InvalidTimeZone;
    defer c.CFRelease(zone);
    const name = try systemNameFrom(allocator, zone);
    defer allocator.free(name);
    try std.testing.expectEqualStrings("America/Los_Angeles", name);
    const unsupported = c.CFTimeZoneCreateWithTimeIntervalFromGMT(null, 3600) orelse return error.OutOfMemory;
    defer c.CFRelease(unsupported);
    const fallback = try systemNameFrom(allocator, unsupported);
    defer allocator.free(fallback);
    try std.testing.expectEqualStrings("UTC", fallback);
    const actual = try systemName(allocator);
    defer allocator.free(actual);
    var actual_zone = try Zone.init(actual);
    actual_zone.deinit();
}

test "zone validation and explicit UTC default" {
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

test "Monday weeks include Sunday, cross years, and use actual DST boundaries" {
    var zone = try Zone.init("America/Los_Angeles");
    defer zone.deinit();
    for ([_]Interval{
        .{ .start_utc_seconds = 1709539200, .end_utc_seconds = 1710140400 }, // 167 hours
        .{ .start_utc_seconds = 1730098800, .end_utc_seconds = 1730707200 }, // 169 hours
        .{ .start_utc_seconds = 1735545600, .end_utc_seconds = 1736150400 }, // Dec 30–Jan 6
    }) |week| {
        try std.testing.expectEqualDeep(week, try zone.weekAt(week.start_utc_seconds));
        try std.testing.expectEqualDeep(week, try zone.weekAt(week.end_utc_seconds - 1));
        try std.testing.expectEqual(week.start_utc_seconds, (try zone.weekAt(week.start_utc_seconds - 1)).end_utc_seconds);
        try std.testing.expectEqual(week.end_utc_seconds, (try zone.weekAt(week.end_utc_seconds)).start_utc_seconds);
    }
    var utc = try Zone.init(null);
    defer utc.deinit();
    try std.testing.expectEqualDeep(Interval{ .start_utc_seconds = -259200, .end_utc_seconds = 345600 }, try utc.weekAt(-1));
    // Monday UTC is still Sunday in Los Angeles.
    try std.testing.expectEqual(@as(i64, 1710115200), (try utc.weekAt(1710115200)).start_utc_seconds);
    try std.testing.expectEqual(@as(i64, 1709539200), (try zone.weekAt(1710115200)).start_utc_seconds);
    try std.testing.expectError(error.TimestampOutOfRange, zone.weekAt(std.math.maxInt(i64)));
}
