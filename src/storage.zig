//! Locked history replay and durable transition appends.
const std = @import("std");
const codec = @import("history.zig");
const History = codec.History;

/// Owns the file lock and replayed history. Do not copy.
pub const Store = struct {
    file: std.Io.File,
    history: History,
    end_offset: u64,
    write_failed: bool = false,

    /// Parent directories must exist. Never truncates or repairs existing data.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Store {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{
            .read = true,
            .truncate = false,
            .permissions = .fromMode(0o600),
        });
        errdefer file.close(io);
        if (!try file.tryLock(io, .exclusive)) return error.HistoryLocked;
        var reader = file.reader(io, &.{});
        const source = reader.interface.allocRemaining(allocator, .unlimited) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            else => |e| return e,
        };
        defer allocator.free(source);
        return .{ .file = file, .history = try History.replay(allocator, source), .end_offset = source.len };
    }

    /// Persist and sync before committing in-memory state. A failed write requires restart.
    /// The caller must report failure as uncertain: disk may contain part or all of the event.
    pub fn append(self: *Store, io: std.Io, event: codec.Event) !void {
        try self.appendWith(event, FileSink{ .file = self.file, .io = io });
    }

    fn appendWith(self: *Store, event: codec.Event, sink: anytype) !void {
        if (self.write_failed) return error.HistoryWriteBlocked;
        const allocator = self.history.arena.child_allocator;
        const line = try codec.encode(allocator, event);
        defer allocator.free(line);
        const prepared = try self.history.prepare(event);
        const next_offset = try std.math.add(u64, self.end_offset, line.len);
        // After I/O starts, neither retry nor rollback can safely resolve durability.
        errdefer self.write_failed = true;
        try sink.write(line, self.end_offset);
        try sink.sync();
        self.history.commit(prepared);
        self.end_offset = next_offset;
    }

    const FileSink = struct {
        file: std.Io.File,
        io: std.Io,

        fn write(self: FileSink, bytes: []const u8, offset: u64) !void {
            try self.file.writePositionalAll(self.io, bytes, offset);
        }

        fn sync(self: FileSink) !void {
            try self.file.sync(self.io);
        }
    };

    pub fn deinit(self: *Store, io: std.Io) void {
        self.history.deinit();
        self.file.close(io);
        self.* = undefined;
    }
};

const test_start: codec.Event = .{ .version = 1, .change = .{ .start = .{
    .session_id = 1,
    .activity = .{ .id = "work", .name = "Work" },
    .start_utc_ns = 100,
} } };
const test_stop: codec.Stop = .{
    .session_id = 1,
    .activity = .{ .id = "work", .name = "Work" },
    .end_utc_ns = 200,
    .duration_ns = 100,
};

fn testPath(tmp: *std.testing.TmpDir) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buffer);
    return std.fs.path.join(std.testing.allocator, &.{ buffer[0..len], "history.jsonl" });
}

test "durable start switch stop, invalid transitions and restart" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(&tmp);
    defer std.testing.allocator.free(path);
    var offset: u64 = 0;
    {
        var store = try Store.open(std.testing.allocator, io, path);
        defer store.deinit(io);
        try std.testing.expectError(error.NotRunning, store.append(io, .{ .version = 1, .change = .{ .stop = test_stop } }));
        try std.testing.expectEqual(@as(u64, 0), (try store.file.stat(io)).size);
        try store.append(io, test_start);
        const before = store.end_offset;
        try std.testing.expectError(error.AlreadyRunning, store.append(io, test_start));
        try std.testing.expectEqual(before, (try store.file.stat(io)).size);
        const next: codec.Start = .{ .session_id = 2, .activity = .{ .id = "rest", .name = "Rest" }, .start_utc_ns = 200 };
        var invalid = next;
        invalid.session_id = 1;
        try std.testing.expectError(error.ReusedSessionId, store.append(io, .{ .version = 1, .change = .{ .switch_activity = .{ .stop = test_stop, .start = invalid } } }));
        try std.testing.expectEqual(before, (try store.file.stat(io)).size);
        try std.testing.expectEqual(@as(usize, 0), store.history.sessions.items.len);
        try std.testing.expectEqual(@as(u64, 1), store.history.unfinished.?.session_id);
        try store.append(io, .{ .version = 1, .change = .{ .switch_activity = .{ .stop = test_stop, .start = next } } });
        try store.append(io, .{ .version = 1, .change = .{ .stop = .{ .session_id = 2, .activity = next.activity, .end_utc_ns = 300, .duration_ns = 100 } } });
        offset = store.end_offset;
        try std.testing.expectEqual(offset, (try store.file.stat(io)).size);
    }
    var reopened = try Store.open(std.testing.allocator, io, path);
    defer reopened.deinit(io);
    try std.testing.expectEqual(@as(usize, 2), reopened.history.sessions.items.len);
    try std.testing.expect(reopened.history.unfinished == null);
    try std.testing.expectEqual(offset, reopened.end_offset);
    const bytes = try tmp.dir.readFileAlloc(io, "history.jsonl", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, bytes, "\n"));
}

const FailingSink = struct {
    file: std.Io.File,
    partial: bool,

    fn write(self: FailingSink, bytes: []const u8, offset: u64) !void {
        try self.file.writePositionalAll(std.testing.io, if (self.partial) bytes[0..7] else bytes, offset);
        if (self.partial) return error.InjectedWriteFailure;
    }

    fn sync(_: FailingSink) !void {
        return error.InjectedSyncFailure;
    }
};

test "partial write and sync failures preserve state and block all further appends" {
    const io = std.testing.io;
    for ([_]bool{ true, false }) |partial| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try testPath(&tmp);
        defer std.testing.allocator.free(path);
        {
            var store = try Store.open(std.testing.allocator, io, path);
            defer store.deinit(io);
            const expected = if (partial) error.InjectedWriteFailure else error.InjectedSyncFailure;
            try std.testing.expectError(expected, store.appendWith(test_start, FailingSink{ .file = store.file, .partial = partial }));
            try std.testing.expect(store.history.unfinished == null);
            try std.testing.expectEqual(@as(u64, 0), store.history.last_session_id);
            try std.testing.expectEqual(@as(u64, 0), store.end_offset);
            const size = (try store.file.stat(io)).size;
            try std.testing.expect(size > 0);
            try std.testing.expectError(error.HistoryWriteBlocked, store.append(io, test_start));
            try std.testing.expectEqual(size, (try store.file.stat(io)).size);
        }
        if (partial) {
            try std.testing.expectError(error.IncompleteTrailingRecord, Store.open(std.testing.allocator, io, path));
        } else {
            var reopened = try Store.open(std.testing.allocator, io, path);
            defer reopened.deinit(io);
            try std.testing.expect(reopened.history.unfinished != null);
        }
    }
}

test "durable discard preserves original bytes and survives restart" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(&tmp);
    defer std.testing.allocator.free(path);
    const discard: codec.Event = .{ .version = 1, .change = .{ .discard = .{ .session_id = 1 } } };
    {
        var store = try Store.open(std.testing.allocator, io, path);
        defer store.deinit(io);
        try std.testing.expectError(error.NotRunning, store.append(io, discard));
        try store.append(io, test_start);
    }
    const original = try tmp.dir.readFileAlloc(io, "history.jsonl", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(original);
    {
        var store = try Store.open(std.testing.allocator, io, path);
        defer store.deinit(io);
        var wrong = discard;
        wrong.change.discard.session_id = 2;
        try std.testing.expectError(error.SessionMismatch, store.append(io, wrong));
        try std.testing.expectEqual(original.len, (try store.file.stat(io)).size);
        try store.append(io, discard);
        try std.testing.expect(store.history.unfinished == null);
    }
    var reopened = try Store.open(std.testing.allocator, io, path);
    defer reopened.deinit(io);
    try std.testing.expect(reopened.history.unfinished == null);
    try std.testing.expectEqual(@as(usize, 0), reopened.history.sessions.items.len);
    try std.testing.expectEqual(@as(u64, 1), reopened.history.last_session_id);
    try std.testing.expectError(error.ReusedSessionId, reopened.append(io, test_start));
    const bytes = try tmp.dir.readFileAlloc(io, "history.jsonl", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, original));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, bytes, "\n"));
}

test "failed stop switch and discard retain the running session" {
    const io = std.testing.io;
    const next: codec.Start = .{ .session_id = 2, .activity = .{ .id = "rest", .name = "Rest" }, .start_utc_ns = 200 };
    const events = [_]codec.Event{
        .{ .version = 1, .change = .{ .stop = test_stop } },
        .{ .version = 1, .change = .{ .switch_activity = .{ .stop = test_stop, .start = next } } },
        .{ .version = 1, .change = .{ .discard = .{ .session_id = 1 } } },
    };
    for (events) |event| {
        for ([_]bool{ true, false }) |partial| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const path = try testPath(&tmp);
            defer std.testing.allocator.free(path);
            var store = try Store.open(std.testing.allocator, io, path);
            defer store.deinit(io);
            try store.append(io, test_start);
            const before = store.end_offset;
            const expected = if (partial) error.InjectedWriteFailure else error.InjectedSyncFailure;
            try std.testing.expectError(expected, store.appendWith(event, FailingSink{ .file = store.file, .partial = partial }));
            try std.testing.expectEqualDeep(test_start.change.start, store.history.unfinished.?);
            try std.testing.expectEqual(@as(usize, 0), store.history.sessions.items.len);
            try std.testing.expectEqual(@as(u64, 1), store.history.last_session_id);
            try std.testing.expectEqual(before, store.end_offset);
            const size = (try store.file.stat(io)).size;
            try std.testing.expectError(error.HistoryWriteBlocked, store.append(io, event));
            try std.testing.expectEqual(size, (try store.file.stat(io)).size);
        }
    }
}

test "store creation, lock release and unfinished replay" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const path = try std.fs.path.join(allocator, &.{ buffer[0..len], "history.jsonl" });
    defer allocator.free(path);
    {
        var store = try Store.open(allocator, io, path);
        defer store.deinit(io);
        try std.testing.expectEqual(@as(usize, 0), store.history.sessions.items.len);
        try std.testing.expectError(error.HistoryLocked, Store.open(allocator, io, path));
    }
    const start = try codec.encode(allocator, .{ .version = 1, .change = .{ .start = .{
        .session_id = 1,
        .activity = .{ .id = "old", .name = "Old name" },
        .start_utc_ns = 1,
    } } });
    defer allocator.free(start);
    try tmp.dir.writeFile(io, .{ .sub_path = "history.jsonl", .data = start });
    {
        var store = try Store.open(allocator, io, path);
        defer store.deinit(io);
        try std.testing.expectEqualStrings("Old name", store.history.unfinished.?.activity.name);
    }
    const stop = try codec.encode(allocator, .{ .version = 1, .change = .{ .stop = .{
        .session_id = 1,
        .activity = .{ .id = "old", .name = "Old name" },
        .end_utc_ns = 2,
        .duration_ns = 1,
    } } });
    defer allocator.free(stop);
    const completed = try std.mem.concat(allocator, u8, &.{ start, stop });
    defer allocator.free(completed);
    try tmp.dir.writeFile(io, .{ .sub_path = "history.jsonl", .data = completed });
    for (0..2) |_| {
        var store = try Store.open(allocator, io, path);
        defer store.deinit(io);
        try std.testing.expect(store.history.unfinished == null);
        try std.testing.expectEqual(@as(usize, 1), store.history.sessions.items.len);
    }
}
