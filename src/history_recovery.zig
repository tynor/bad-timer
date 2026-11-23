//! Explicit recovery to a separate file; never edits the uncertain source.
const std = @import("std");
const codec = @import("history.zig");

pub const Report = struct {
    retained_bytes: usize,
    omitted_bytes: usize,
    completed_sessions: usize,
    unfinished_session_id: ?u64,
};

/// Call only after explicit authorization to omit the non-LF-terminated tail.
/// Locks an existing source for the whole operation and validates every complete
/// record. Even valid JSON without LF is omitted, never guessed to be committed.
/// Publishes a synced, private file without replacing any destination. The source
/// remains the backup; callers must preserve it and surface the report's uncertainty.
/// Parent directories must exist. Directory metadata is not synced; temporary-file
/// cleanup is best effort. Reads the whole source into memory, like Store.open.
/// Normal timer startup never invokes this automatically or replaces active history.
pub fn recover(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, source_path: []const u8, destination_path: []const u8) !Report {
    return recoverWith(allocator, io, dir, source_path, destination_path, FileSink{});
}

fn recoverWith(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, source_path: []const u8, destination_path: []const u8, sink: anytype) !Report {
    const source_file = try dir.openFile(io, source_path, .{});
    defer source_file.close(io);
    if (!try source_file.tryLock(io, .exclusive)) return error.HistoryLocked;
    var reader = source_file.reader(io, &.{});
    const source = reader.interface.allocRemaining(allocator, .unlimited) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => |e| return e,
    };
    defer allocator.free(source);
    const length = if (std.mem.lastIndexOfScalar(u8, source, '\n')) |index| index + 1 else 0;
    var history = try codec.History.replay(allocator, source[0..length]);
    defer history.deinit();
    if (length == source.len) return error.NoIncompleteTrailingRecord;
    const report: Report = .{
        .retained_bytes = length,
        .omitted_bytes = source.len - length,
        .completed_sessions = history.sessions.items.len,
        .unfinished_session_id = if (history.unfinished) |session| session.session_id else null,
    };
    var destination = try dir.createFileAtomic(io, destination_path, .{ .permissions = .fromMode(0o600), .replace = false });
    defer destination.deinit(io);
    try sink.writeAndSync(io, destination.file, source[0..length]);
    try destination.link(io);
    return report;
}

const FileSink = struct {
    fn writeAndSync(_: FileSink, io: std.Io, file: std.Io.File, bytes: []const u8) !void {
        try file.writePositionalAll(io, bytes, 0);
        try file.sync(io);
    }
};

const start = "{\"version\":1,\"change\":{\"start\":{\"session_id\":1,\"activity\":{\"id\":\"work\",\"name\":\"Work\"},\"start_utc_ns\":100}}}\n";
const stop = "{\"version\":1,\"change\":{\"stop\":{\"session_id\":1,\"activity\":{\"id\":\"work\",\"name\":\"Work\"},\"end_utc_ns\":200,\"duration_ns\":100}}}\n";

fn expectBytes(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    const actual = try dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

fn expectEntries(dir: std.Io.Dir, expected: usize) !void {
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    try std.testing.expectEqual(expected, count);
}

test "recover partial tails byte-for-byte, preserving source and unfinished sessions" {
    const io = std.testing.io;
    // Include every nonempty partial stop, including complete JSON without its LF.
    for (1..stop.len) |tail_length| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ start, stop[0..tail_length] });
        defer std.testing.allocator.free(source);
        try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = source });
        const report = try recover(std.testing.allocator, io, tmp.dir, "source", "recovered");
        try std.testing.expectEqual(Report{ .retained_bytes = start.len, .omitted_bytes = tail_length, .completed_sessions = 0, .unfinished_session_id = 1 }, report);
        try expectBytes(tmp.dir, "source", source);
        try expectBytes(tmp.dir, "recovered", start);
        try std.testing.expectEqual(@as(u32, 0o600), (try tmp.dir.statFile(io, "recovered", .{})).permissions.toMode() & 0o777);
        try expectEntries(tmp.dir, 2);
    }
}

test "completed sessions survive, no complete records can recover to empty history" {
    const io = std.testing.io;
    for ([_][]const u8{ start ++ stop, "" }) |prefix| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, "uncertain" });
        defer std.testing.allocator.free(source);
        try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = source });
        const report = try recover(std.testing.allocator, io, tmp.dir, "source", "recovered");
        try std.testing.expectEqual(@as(usize, if (prefix.len == 0) 0 else 1), report.completed_sessions);
        try std.testing.expectEqual(@as(?u64, null), report.unfinished_session_id);
        try expectBytes(tmp.dir, "source", source);
        try expectBytes(tmp.dir, "recovered", prefix);
        var replayed = try codec.History.replay(std.testing.allocator, prefix);
        defer replayed.deinit();
        try std.testing.expectEqual(report.completed_sessions, replayed.sessions.items.len);
    }
}

test "reject complete corruption, invalid transitions, and logs without tails before publishing" {
    const io = std.testing.io;
    for ([_]struct { source: []const u8, err: anyerror }{
        .{ .source = "", .err = error.NoIncompleteTrailingRecord },
        .{ .source = start ++ stop, .err = error.NoIncompleteTrailingRecord },
        .{ .source = "\npartial", .err = error.EmptyHistoryRecord },
        .{ .source = "{bad}\npartial", .err = error.SyntaxError },
        .{ .source = stop ++ "partial", .err = error.NotRunning },
        .{ .source = start ++ start ++ "partial", .err = error.AlreadyRunning },
    }) |case| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = case.source });
        try std.testing.expectError(case.err, recover(std.testing.allocator, io, tmp.dir, "source", "recovered"));
        try expectBytes(tmp.dir, "source", case.source);
        try expectEntries(tmp.dir, 1);
    }
}

const FailingSink = struct {
    partial: bool,
    fn writeAndSync(self: FailingSink, io: std.Io, file: std.Io.File, bytes: []const u8) !void {
        try file.writePositionalAll(io, if (self.partial) bytes[0..7] else bytes, 0);
        return if (self.partial) error.InjectedWriteFailure else error.InjectedSyncFailure;
    }
};

test "write and sync failures preserve source and clean unpublished files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = start ++ "partial" });
    for ([_]bool{ true, false }) |partial| {
        try std.testing.expectError(if (partial) error.InjectedWriteFailure else error.InjectedSyncFailure, recoverWith(std.testing.allocator, io, tmp.dir, "source", "recovered", FailingSink{ .partial = partial }));
        try expectBytes(tmp.dir, "source", start ++ "partial");
        try expectEntries(tmp.dir, 1);
    }
}

test "exclusive lock, missing source, existing destinations and publication failures" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try std.testing.expectError(error.FileNotFound, recover(std.testing.allocator, io, tmp.dir, "missing", "recovered"));
    try expectEntries(tmp.dir, 0);
    try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = start ++ "partial" });
    {
        const file = try tmp.dir.openFile(io, "source", .{});
        defer file.close(io);
        try std.testing.expect(try file.tryLock(io, .exclusive));
        try std.testing.expectError(error.HistoryLocked, recover(std.testing.allocator, io, tmp.dir, "source", "recovered"));
        try expectEntries(tmp.dir, 1);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "existing", .data = "keep" });
    try tmp.dir.symLink(io, "absent", "link", .{});
    try tmp.dir.createDir(io, "directory", .default_dir);
    for ([_][]const u8{ "source", "existing", "link", "directory" }) |destination| {
        try std.testing.expectError(error.PathAlreadyExists, recover(std.testing.allocator, io, tmp.dir, "source", destination));
        try expectEntries(tmp.dir, 4);
    }
    try std.testing.expectError(error.FileNotFound, recover(std.testing.allocator, io, tmp.dir, "source", "missing/recovered"));
    try expectBytes(tmp.dir, "source", start ++ "partial");
    try expectBytes(tmp.dir, "existing", "keep");
    try expectEntries(tmp.dir, 4);
}
