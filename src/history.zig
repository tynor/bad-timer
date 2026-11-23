//! In-memory versioned JSON Lines codec and strict history replay. No filesystem I/O.
const std = @import("std");
const timer = @import("root.zig");

pub const Start = struct {
    session_id: u64,
    activity: timer.Activity,
    start_utc_ns: i128,
};

pub const Stop = struct {
    session_id: u64,
    activity: timer.Activity,
    end_utc_ns: i128,
    duration_ns: u64,
};

pub const Event = struct {
    version: u32,
    change: union(enum) {
        start: Start,
        stop: Stop,
        switch_activity: struct { stop: Stop, start: Start },
        discard: struct { session_id: u64 },
    },
};

fn validateActivity(activity: timer.Activity) !void {
    if (std.mem.trim(u8, activity.id, " \t\r\n").len == 0 or
        std.mem.trim(u8, activity.name, " \t\r\n").len == 0) return error.InvalidActivity;
}

fn validate(event: Event) !void {
    if (event.version != 1) return error.UnsupportedHistoryVersion;
    switch (event.change) {
        .start => |start| {
            if (start.session_id == 0) return error.InvalidSessionId;
            try validateActivity(start.activity);
        },
        .discard => |discard| {
            if (discard.session_id == 0) return error.InvalidSessionId;
        },
        .stop => |stop| {
            if (stop.session_id == 0) return error.InvalidSessionId;
            try validateActivity(stop.activity);
        },
        .switch_activity => |change| {
            try validate(.{ .version = 1, .change = .{ .stop = change.stop } });
            try validate(.{ .version = 1, .change = .{ .start = change.start } });
            if (change.stop.end_utc_ns != change.start.start_utc_ns) return error.InvalidSwitchBoundary;
            if (std.mem.eql(u8, change.stop.activity.id, change.start.activity.id)) return error.InvalidSwitchActivity;
        },
    }
}

/// Returns one owned, newline-terminated record. Transition validity requires replay.
pub fn encode(allocator: std.mem.Allocator, event: Event) ![]u8 {
    try validate(event);
    const json = try std.json.Stringify.valueAlloc(allocator, event, .{});
    defer allocator.free(json);
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

/// Owns all strings and sessions, independently of input/config. Do not copy.
pub const History = struct {
    arena: std.heap.ArenaAllocator,
    sessions: std.ArrayList(timer.Session) = .empty,
    unfinished: ?Start = null,
    last_session_id: u64 = 0,

    pub fn deinit(self: *History) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Empty history is valid; every nonempty record must end in LF.
    /// Any error rejects the entire history without repairing or skipping bytes.
    pub fn replay(allocator: std.mem.Allocator, source: []const u8) !History {
        var history: History = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
        errdefer history.deinit();
        if (source.len != 0 and source[source.len - 1] != '\n') return error.IncompleteTrailingRecord;
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            if (lines.peek() == null) break; // Final empty segment after the required LF.
            if (line.len == 0) return error.EmptyHistoryRecord;
            const parsed = try std.json.parseFromSlice(Event, history.arena.allocator(), line, .{ .allocate = .alloc_always });
            // The parent arena retains the parsed arena and its strings until deinit.
            try validate(parsed.value);
            try history.apply(parsed.value);
        }
        return history;
    }

    fn begin(self: *History, start: Start) !void {
        if (self.unfinished != null) return error.AlreadyRunning;
        if (start.session_id <= self.last_session_id) return error.ReusedSessionId;
        self.unfinished = start;
        self.last_session_id = start.session_id;
    }

    fn end(self: *History, stop: Stop) !void {
        const start = self.unfinished orelse return error.NotRunning;
        if (start.session_id != stop.session_id or
            !std.mem.eql(u8, start.activity.id, stop.activity.id) or
            !std.mem.eql(u8, start.activity.name, stop.activity.name)) return error.SessionMismatch;
        try self.sessions.append(self.arena.allocator(), .{
            .activity = start.activity,
            .start_utc_ns = start.start_utc_ns,
            .end_utc_ns = stop.end_utc_ns,
            .duration_ns = stop.duration_ns,
        });
        self.unfinished = null;
    }

    /// Validate and reserve all resources before persistence. Does not change logical state.
    /// Commit the returned event before preparing another; its start strings are owned here.
    pub fn prepare(self: *History, event: Event) !Event {
        try validate(event);
        // Reuse replay's transition checks on a disposable, constant-size history.
        var trial: History = .{
            .arena = std.heap.ArenaAllocator.init(self.arena.child_allocator),
            .unfinished = self.unfinished,
            .last_session_id = self.last_session_id,
        };
        defer trial.deinit();
        try trial.apply(event);
        if (event.change == .stop or event.change == .switch_activity)
            try self.sessions.ensureUnusedCapacity(self.arena.allocator(), 1);
        var owned = event;
        const start: ?*Start = switch (owned.change) {
            .start => |*start| start,
            .switch_activity => |*change| &change.start,
            .stop, .discard => null,
        };
        if (start) |s| {
            s.activity.id = try self.arena.allocator().dupe(u8, s.activity.id);
            s.activity.name = try self.arena.allocator().dupe(u8, s.activity.name);
        }
        return owned;
    }

    /// Only accepts an event returned by prepare, with no intervening state changes.
    pub fn commit(self: *History, prepared: Event) void {
        self.apply(prepared) catch unreachable; // prepare validated and reserved capacity.
    }

    fn apply(self: *History, event: Event) !void {
        switch (event.change) {
            .start => |start| try self.begin(start),
            .stop => |stop| try self.end(stop),
            .discard => |discard| {
                const start = self.unfinished orelse return error.NotRunning;
                if (start.session_id != discard.session_id) return error.SessionMismatch;
                self.unfinished = null;
            },
            .switch_activity => |change| {
                try self.end(change.stop);
                try self.begin(change.start);
            },
        }
    }
};

const work: timer.Activity = .{ .id = "work", .name = "Café, \"work\"\nnext" };
const rest: timer.Activity = .{ .id = "rest", .name = "Break" };
const start_event: Event = .{ .version = 1, .change = .{ .start = .{ .session_id = 1, .activity = work, .start_utc_ns = 100 } } };
const stop_event: Event = .{ .version = 1, .change = .{ .stop = .{ .session_id = 1, .activity = work, .end_utc_ns = -100, .duration_ns = 20 } } };

fn replayEvents(events: []const Event) !History {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    for (events) |event| {
        const line = try encode(std.testing.allocator, event);
        defer std.testing.allocator.free(line);
        try bytes.appendSlice(std.testing.allocator, line);
    }
    return History.replay(std.testing.allocator, bytes.items);
}

test "round trip owns names and preserves durations despite backwards UTC" {
    var history = try replayEvents(&.{ start_event, stop_event });
    defer history.deinit();
    try std.testing.expectEqual(@as(usize, 1), history.sessions.items.len);
    try std.testing.expectEqualDeep(timer.Session{ .activity = work, .start_utc_ns = 100, .end_utc_ns = -100, .duration_ns = 20 }, history.sessions.items[0]);
    try std.testing.expectEqual(null, history.unfinished);
}

test "atomic switch completes old session and retains unfinished new session" {
    const change: Event = .{ .version = 1, .change = .{ .switch_activity = .{
        .stop = stop_event.change.stop,
        .start = .{ .session_id = 2, .activity = rest, .start_utc_ns = -100 },
    } } };
    var history = try replayEvents(&.{ start_event, change });
    defer history.deinit();
    try std.testing.expectEqual(@as(usize, 1), history.sessions.items.len);
    try std.testing.expectEqualDeep(rest, history.unfinished.?.activity);
    try std.testing.expectEqual(history.sessions.items[0].end_utc_ns, history.unfinished.?.start_utc_ns);
    var invalid = change;
    invalid.change.switch_activity.start.start_utc_ns = 0;
    try std.testing.expectError(error.InvalidSwitchBoundary, replayEvents(&.{ start_event, invalid }));
    invalid = change;
    invalid.change.switch_activity.start.session_id = 1;
    try std.testing.expectError(error.ReusedSessionId, replayEvents(&.{ start_event, invalid }));
}

test "discard clears only the matching unfinished session and never reuses its ID" {
    const discard: Event = .{ .version = 1, .change = .{ .discard = .{ .session_id = 1 } } };
    var history = try replayEvents(&.{ start_event, stop_event, .{ .version = 1, .change = .{ .start = .{
        .session_id = 2,
        .activity = work,
        .start_utc_ns = 300,
    } } }, .{ .version = 1, .change = .{ .discard = .{ .session_id = 2 } } } });
    defer history.deinit();
    try std.testing.expect(history.unfinished == null);
    try std.testing.expectEqual(@as(usize, 1), history.sessions.items.len);
    try std.testing.expectEqual(@as(u64, 2), history.last_session_id);
    try std.testing.expectError(error.NotRunning, replayEvents(&.{discard}));
    try std.testing.expectError(error.NotRunning, replayEvents(&.{ start_event, discard, discard }));
    try std.testing.expectError(error.ReusedSessionId, replayEvents(&.{ start_event, discard, start_event }));
    var invalid = discard;
    invalid.change.discard.session_id = 2;
    try std.testing.expectError(error.SessionMismatch, replayEvents(&.{ start_event, invalid }));
    invalid.change.discard.session_id = 0;
    try std.testing.expectError(error.InvalidSessionId, replayEvents(&.{invalid}));
}

test "empty history and unfinished start do not invent sessions" {
    var empty = try History.replay(std.testing.allocator, "");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.sessions.items.len);
    var history = try replayEvents(&.{start_event});
    defer history.deinit();
    try std.testing.expectEqual(@as(usize, 0), history.sessions.items.len);
    try std.testing.expectEqualDeep(start_event.change.start, history.unfinished.?);
}

test "invalid transitions and mismatched snapshots reject history" {
    try std.testing.expectError(error.NotRunning, replayEvents(&.{stop_event}));
    try std.testing.expectError(error.AlreadyRunning, replayEvents(&.{ start_event, start_event }));
    try std.testing.expectError(error.ReusedSessionId, replayEvents(&.{ start_event, stop_event, start_event }));
    var wrong = stop_event;
    wrong.change.stop.session_id = 2;
    try std.testing.expectError(error.SessionMismatch, replayEvents(&.{ start_event, wrong }));
    wrong = stop_event;
    wrong.change.stop.activity.name = "Renamed";
    try std.testing.expectError(error.SessionMismatch, replayEvents(&.{ start_event, wrong }));
}

test "strict records reject partial, blank, malformed, unknown and duplicate fields" {
    try std.testing.expectError(error.IncompleteTrailingRecord, History.replay(std.testing.allocator, "{}"));
    try std.testing.expectError(error.EmptyHistoryRecord, History.replay(std.testing.allocator, "\n"));
    for ([_][]const u8{ "{\n", "{}\n", "{\"version\":1,\"version\":1}\n", "{\"version\":1,\"extra\":true}\n" }) |source| {
        if (History.replay(std.testing.allocator, source)) |value| {
            var unexpected = value;
            unexpected.deinit();
            return error.ExpectedRejection;
        } else |_| {}
    }
    const valid = try encode(std.testing.allocator, start_event);
    defer std.testing.allocator.free(valid);
    const corrupt = try std.fmt.allocPrint(std.testing.allocator, "{s}{{\n", .{valid});
    defer std.testing.allocator.free(corrupt);
    if (History.replay(std.testing.allocator, corrupt)) |value| {
        var unexpected = value;
        unexpected.deinit();
        return error.ExpectedRejection;
    } else |_| {}
    try std.testing.expectError(error.IncompleteTrailingRecord, History.replay(std.testing.allocator, valid[0 .. valid.len - 1]));
    const future = "{\"version\":2,\"change\":{\"start\":{\"session_id\":1,\"activity\":{\"id\":\"work\",\"name\":\"Work\"},\"start_utc_ns\":0}}}\n";
    try std.testing.expectError(error.UnsupportedHistoryVersion, History.replay(std.testing.allocator, future));
    var invalid = start_event;
    invalid.version = 2;
    try std.testing.expectError(error.UnsupportedHistoryVersion, replayEvents(&.{invalid}));
    invalid = start_event;
    invalid.change.start.activity.id = " ";
    try std.testing.expectError(error.InvalidActivity, replayEvents(&.{invalid}));
    invalid = start_event;
    invalid.change.start.session_id = 0;
    try std.testing.expectError(error.InvalidSessionId, replayEvents(&.{invalid}));
}
