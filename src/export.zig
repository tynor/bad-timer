//! CSV encoding and atomic, no-overwrite publishing of completed sessions.
const std = @import("std");
const timer = @import("root.zig");
const header = "activity_id,activity_name,start_utc,end_utc,duration_seconds\r\n";

/// Returns owned CSV bytes in input order. Caller frees the result.
/// Text is always quoted; dangerous spreadsheet prefixes receive an apostrophe.
pub fn encode(allocator: std.mem.Allocator, sessions: []const timer.Session) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const writer = &output.writer;
    try writer.writeAll(header);
    for (sessions) |session| {
        try text(writer, session.activity.id);
        try writer.writeByte(',');
        try text(writer, session.activity.name);
        try writer.writeByte(',');
        try timestamp(writer, session.start_utc_ns);
        try writer.writeByte(',');
        try timestamp(writer, session.end_utc_ns);
        try writer.print(",{d}.{d:0>9}\r\n", .{
            session.duration_ns / std.time.ns_per_s,
            session.duration_ns % std.time.ns_per_s,
        });
    }
    return output.toOwnedSlice();
}

/// Encode completed sessions, sync a private temporary file, then publish without
/// replacing any existing destination (including symlinks). Parent directories must
/// exist. Does not sync directory metadata: power-loss durability is not guaranteed.
/// Temporary-file cleanup is best effort, including after a failed publish.
pub fn publish(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, sessions: []const timer.Session) !void {
    const bytes = try encode(allocator, sessions);
    defer allocator.free(bytes);
    try publishBytes(io, dir, path, bytes, FileSink{});
}

fn publishBytes(io: std.Io, dir: std.Io.Dir, path: []const u8, bytes: []const u8, sink: anytype) !void {
    var file = try dir.createFileAtomic(io, path, .{ .permissions = .fromMode(0o600), .replace = false });
    defer file.deinit(io);
    try sink.writeAndSync(io, file.file, bytes);
    try file.link(io);
}

const FileSink = struct {
    fn writeAndSync(_: FileSink, io: std.Io, file: std.Io.File, bytes: []const u8) !void {
        try file.writePositionalAll(io, bytes, 0);
        try file.sync(io);
    }
};

fn text(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    // Also guard formulas hidden behind leading ASCII whitespace/control bytes.
    var first: usize = 0;
    while (first < value.len and value[first] <= ' ') : (first += 1) {}
    if ((first < value.len and std.mem.indexOfScalar(u8, "=+-@", value[first]) != null) or
        (value.len > 0 and std.mem.indexOfScalar(u8, "\t\r\n", value[0]) != null))
        try writer.writeByte('\'');
    for (value) |byte| {
        try writer.writeByte(byte);
        if (byte == '"') try writer.writeByte('"');
    }
    try writer.writeByte('"');
}

fn timestamp(writer: *std.Io.Writer, ns: i128) !void {
    const seconds = @divFloor(ns, std.time.ns_per_s);
    if (seconds < -62135596800 or seconds > 253402300799) return error.TimestampOutOfRange;
    var days = @divFloor(seconds, 86400);
    var year: u16 = 1970;
    while (days < 0) {
        year -= 1;
        days += std.time.epoch.getDaysInYear(year);
    }
    while (days >= std.time.epoch.getDaysInYear(year)) {
        days -= std.time.epoch.getDaysInYear(year);
        year += 1;
    }
    const date = (std.time.epoch.YearAndDay{ .year = year, .day = @intCast(days) }).calculateMonthDay();
    const time = std.time.epoch.DaySeconds{ .secs = @intCast(@mod(seconds, 86400)) };
    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}Z", .{
        year,                                            date.month.numeric(),      @as(u8, date.day_index) + 1,
        time.getHoursIntoDay(),                          time.getMinutesIntoHour(), time.getSecondsIntoMinute(),
        @as(u32, @intCast(@mod(ns, std.time.ns_per_s))),
    });
}

const sample: timer.Session = .{
    .activity = .{ .id = "old-id", .name = "Historical name" },
    .start_utc_ns = -1,
    .end_utc_ns = 1000000001,
    .duration_ns = 2000000003,
};

test "empty history and exact historical session values" {
    const empty = try encode(std.testing.allocator, &.{});
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings(header, empty);
    const csv = try encode(std.testing.allocator, &.{sample});
    defer std.testing.allocator.free(csv);
    try std.testing.expectEqualStrings(header ++
        "\"old-id\",\"Historical name\",1969-12-31T23:59:59.999999999Z,1970-01-01T00:00:01.000000001Z,2.000000003\r\n", csv);
}

test "text quoting and spreadsheet formula neutralization" {
    const cases = [_]struct { value: []const u8, expected: []const u8 }{
        .{ .value = "", .expected = "\"\"" },
        .{ .value = "café,\"work\"\r\nnext", .expected = "\"café,\"\"work\"\"\r\nnext\"" },
        .{ .value = "=1+1", .expected = "\"'=1+1\"" },
        .{ .value = "+cmd", .expected = "\"'+cmd\"" },
        .{ .value = "-1", .expected = "\"'-1\"" },
        .{ .value = "@SUM(A1)", .expected = "\"'@SUM(A1)\"" },
        .{ .value = "  =1", .expected = "\"'  =1\"" },
        .{ .value = "\tplain", .expected = "\"'\tplain\"" },
        .{ .value = "\rplain", .expected = "\"'\rplain\"" },
        .{ .value = "\nplain", .expected = "\"'\nplain\"" },
        .{ .value = "'safe", .expected = "\"'safe\"" },
    };
    for (cases) |case| {
        var session = sample;
        session.activity = .{ .id = case.value, .name = case.value };
        const csv = try encode(std.testing.allocator, &.{session});
        defer std.testing.allocator.free(csv);
        const prefix = try std.fmt.allocPrint(std.testing.allocator, "{s}{s},{s},", .{ header, case.expected, case.expected });
        defer std.testing.allocator.free(prefix);
        try std.testing.expect(std.mem.startsWith(u8, csv, prefix));
    }
}

test "UTC calendar boundaries and nanosecond range" {
    // Independent Unix-second fixtures, checked with Python datetime.
    for ([_]struct { value: []const u8, seconds: i64 }{
        .{ .value = "0001-01-01T00:00:00", .seconds = -62135596800 },
        .{ .value = "1900-03-01T00:00:00", .seconds = -2203891200 },
        .{ .value = "2000-02-29T12:34:56", .seconds = 951827696 },
        .{ .value = "2024-12-31T23:59:59", .seconds = 1735689599 },
        .{ .value = "9999-12-31T23:59:59", .seconds = 253402300799 },
    }) |case| {
        const ns = @as(i128, case.seconds) * std.time.ns_per_s;
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try timestamp(&output.writer, ns);
        const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}.000000000Z", .{case.value});
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, output.written());
    }
    for ([_]i128{ std.math.minInt(i128), -62135596800 * @as(i128, std.time.ns_per_s) - 1, 253402300800 * @as(i128, std.time.ns_per_s), std.math.maxInt(i128) }) |ns| {
        var session = sample;
        session.end_utc_ns = ns;
        try std.testing.expectError(error.TimestampOutOfRange, encode(std.testing.allocator, &.{ sample, session }));
        session.start_utc_ns = ns;
        session.end_utc_ns = 0;
        try std.testing.expectError(error.TimestampOutOfRange, encode(std.testing.allocator, &.{session}));
    }
}

fn expectEntries(dir: std.Io.Dir, expected: usize) !void {
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    try std.testing.expectEqual(expected, count);
}

test "publish exact CSV and empty history without replacing reports" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try publish(std.testing.allocator, io, tmp.dir, "report.csv", &.{sample});
    const bytes = try tmp.dir.readFileAlloc(io, "report.csv", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    const expected = try encode(std.testing.allocator, &.{sample});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, bytes);
    try std.testing.expectEqual(@as(u32, 0o600), (try tmp.dir.statFile(io, "report.csv", .{})).permissions.toMode() & 0o777);
    try std.testing.expectError(error.PathAlreadyExists, publish(std.testing.allocator, io, tmp.dir, "report.csv", &.{}));
    const unchanged = try tmp.dir.readFileAlloc(io, "report.csv", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings(bytes, unchanged);
    try publish(std.testing.allocator, io, tmp.dir, "empty.csv", &.{});
    const empty = try tmp.dir.readFileAlloc(io, "empty.csv", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings(header, empty);
    try expectEntries(tmp.dir, 2);
}

const FailingSink = struct {
    partial: bool,

    fn writeAndSync(self: FailingSink, io: std.Io, file: std.Io.File, bytes: []const u8) !void {
        try file.writePositionalAll(io, if (self.partial) bytes[0..7] else bytes, 0);
        return if (self.partial) error.InjectedWriteFailure else error.InjectedSyncFailure;
    }
};

test "write and sync failures leave no report or temporary file" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for ([_]bool{ true, false }) |partial| {
        const expected = if (partial) error.InjectedWriteFailure else error.InjectedSyncFailure;
        try std.testing.expectError(expected, publishBytes(std.testing.io, tmp.dir, "report.csv", header, FailingSink{ .partial = partial }));
        try expectEntries(tmp.dir, 0);
    }
}

test "publish refuses directories and symlinks and validates before creating files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "directory", .default_dir);
    try std.testing.expectError(error.PathAlreadyExists, publish(std.testing.allocator, io, tmp.dir, "directory", &.{}));
    try tmp.dir.symLink(io, "absent.csv", "link.csv", .{});
    try std.testing.expectError(error.PathAlreadyExists, publish(std.testing.allocator, io, tmp.dir, "link.csv", &.{}));
    var invalid = sample;
    invalid.end_utc_ns = std.math.maxInt(i128);
    try std.testing.expectError(error.TimestampOutOfRange, publish(std.testing.allocator, io, tmp.dir, "invalid.csv", &.{invalid}));
    try std.testing.expectError(error.FileNotFound, publish(std.testing.allocator, io, tmp.dir, "missing/report.csv", &.{}));
    try expectEntries(tmp.dir, 2);
}

test "row order, backwards wall clock, and duration extremes" {
    var first = sample;
    first.start_utc_ns = 1;
    first.end_utc_ns = 0;
    first.duration_ns = 0;
    var second = sample;
    second.duration_ns = std.math.maxInt(u64);
    const csv = try encode(std.testing.allocator, &.{ first, second });
    defer std.testing.allocator.free(csv);
    try std.testing.expect(std.mem.indexOf(u8, csv, "1970-01-01T00:00:00.000000001Z,1970-01-01T00:00:00.000000000Z,0.000000000\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, csv, ",18446744073.709551615\r\n"));
}
