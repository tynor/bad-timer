//! Locked, read-only replay of a history file. No transition writes yet.
const std = @import("std");
const History = @import("history.zig").History;

/// Owns the file lock and replayed history. Do not copy.
pub const Store = struct {
    file: std.Io.File,
    history: History,

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
        return .{ .file = file, .history = try History.replay(allocator, source) };
    }

    pub fn deinit(self: *Store, io: std.Io) void {
        self.history.deinit();
        self.file.close(io);
        self.* = undefined;
    }
};

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
    const codec = @import("history.zig");
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
