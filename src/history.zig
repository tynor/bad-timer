//! In-memory versioned JSON Lines codec and strict history replay. No filesystem I/O.
const std = @import("std");
const timer = @import("root.zig");

pub const Start = struct {
    session_id: u64,
    activity: timer.Activity,
    start_utc_ns: i128,
    time_zone: ?[]const u8 = null,
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
        legacy_timezone: []const u8,
    },
};

fn validateActivity(activity: timer.Activity) !void {
    if (std.mem.trim(u8, activity.id, " \t\r\n").len == 0 or
        std.mem.trim(u8, activity.name, " \t\r\n").len == 0) return error.InvalidActivity;
}

fn validateZone(name: []const u8) !void {
    var zone = try timer.time_zone.Zone.init(name);
    zone.deinit();
}

fn validate(event: Event) !void {
    if (event.version != 1 and event.version != 2) return error.UnsupportedHistoryVersion;
    switch (event.change) {
        .start => |start| {
            if (start.session_id == 0) return error.InvalidSessionId;
            try validateActivity(start.activity);
            if (event.version == 2) {
                try validateZone(start.time_zone orelse return error.MissingSessionTimezone);
            } else if (start.time_zone != null) return error.UnexpectedSessionTimezone;
        },
        .legacy_timezone => |name| {
            if (event.version != 2) return error.UnsupportedHistoryVersion;
            try validateZone(name);
        },
        .discard => |discard| {
            if (discard.session_id == 0) return error.InvalidSessionId;
        },
        .stop => |stop| {
            if (stop.session_id == 0) return error.InvalidSessionId;
            try validateActivity(stop.activity);
        },
        .switch_activity => |change| {
            try validate(.{ .version = event.version, .change = .{ .stop = change.stop } });
            try validate(.{ .version = event.version, .change = .{ .start = change.start } });
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
    legacy_timezone: ?[]const u8 = null,
    upgraded: bool = false,

    pub fn needsLegacyTimezone(self: History) bool {
        if (self.unfinished) |start| if (start.time_zone == null) return true;
        for (self.sessions.items) |session| if (session.time_zone == null) return true;
        return false;
    }

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
            .time_zone = start.time_zone,
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
            .legacy_timezone = self.legacy_timezone,
            .upgraded = self.upgraded,
        };
        defer trial.deinit();
        try trial.apply(event);
        if (event.change == .stop or event.change == .switch_activity)
            try self.sessions.ensureUnusedCapacity(self.arena.allocator(), 1);
        var owned = event;
        const start: ?*Start = switch (owned.change) {
            .start => |*start| start,
            .switch_activity => |*change| &change.start,
            .stop, .discard, .legacy_timezone => null,
        };
        if (start) |s| {
            s.activity.id = try self.arena.allocator().dupe(u8, s.activity.id);
            s.activity.name = try self.arena.allocator().dupe(u8, s.activity.name);
            if (s.time_zone) |name| s.time_zone = try self.arena.allocator().dupe(u8, name);
        }
        if (owned.change == .legacy_timezone)
            owned.change.legacy_timezone = try self.arena.allocator().dupe(u8, owned.change.legacy_timezone);
        return owned;
    }

    /// Only accepts an event returned by prepare, with no intervening state changes.
    pub fn commit(self: *History, prepared: Event) void {
        self.apply(prepared) catch unreachable; // prepare validated and reserved capacity.
    }

    fn apply(self: *History, event: Event) !void {
        if (self.upgraded and event.version == 1) return error.LegacyEventAfterUpgrade;
        switch (event.change) {
            .legacy_timezone => |name| {
                if (self.legacy_timezone != null) return error.DuplicateLegacyTimezone;
                for (self.sessions.items) |*session| if (session.time_zone == null) {
                    session.time_zone = name;
                };
                if (self.unfinished) |*start| if (start.time_zone == null) {
                    start.time_zone = name;
                };
                self.legacy_timezone = name;
            },
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
        if (event.version == 2) self.upgraded = true;
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

test "legacy assignment and zoned switches retain immutable owned session zones" {
    const legacy_start: Start = .{ .session_id = 2, .activity = rest, .start_utc_ns = 200 };
    const assignment: Event = .{ .version = 2, .change = .{ .legacy_timezone = "America/Los_Angeles" } };
    const switched: Event = .{ .version = 2, .change = .{ .switch_activity = .{
        .stop = .{ .session_id = 2, .activity = rest, .end_utc_ns = 300, .duration_ns = 100 },
        .start = .{ .session_id = 3, .activity = work, .start_utc_ns = 300, .time_zone = "Asia/Tokyo" },
    } } };
    var history = try replayEvents(&.{ start_event, stop_event, .{ .version = 1, .change = .{ .start = legacy_start } } });
    defer history.deinit();
    try std.testing.expect(history.needsLegacyTimezone());
    const prepared = try history.prepare(assignment);
    try std.testing.expect(history.sessions.items[0].time_zone == null);
    history.commit(prepared);
    try std.testing.expect(!history.needsLegacyTimezone());
    try std.testing.expectEqualStrings("America/Los_Angeles", history.unfinished.?.time_zone.?);
    try std.testing.expectEqualStrings("America/Los_Angeles", history.sessions.items[0].time_zone.?);
    var text = "Asia/Tokyo".*;
    var borrowed = switched;
    borrowed.change.switch_activity.start.time_zone = &text;
    const owned = try history.prepare(borrowed);
    text[0] = 'X';
    history.commit(owned);
    try std.testing.expectEqualStrings("Asia/Tokyo", history.unfinished.?.time_zone.?);
    try std.testing.expectEqualStrings("America/Los_Angeles", history.sessions.items[1].time_zone.?);
    var replayed = try replayEvents(&.{ start_event, stop_event, .{ .version = 1, .change = .{ .start = legacy_start } }, assignment, switched });
    defer replayed.deinit();
    try std.testing.expectEqualStrings("Asia/Tokyo", replayed.unfinished.?.time_zone.?);
    try std.testing.expectEqualStrings("America/Los_Angeles", replayed.sessions.items[1].time_zone.?);
    try std.testing.expectError(error.DuplicateLegacyTimezone, history.prepare(assignment));
    try std.testing.expectError(error.LegacyEventAfterUpgrade, history.prepare(stop_event));
    history.commit(try history.prepare(.{ .version = 2, .change = .{ .stop = .{ .session_id = 3, .activity = work, .end_utc_ns = 400, .duration_ns = 100 } } }));
    try std.testing.expectEqualStrings("Asia/Tokyo", history.sessions.items[2].time_zone.?);
}

test "version two requires valid timezone identifiers without weakening legacy validation" {
    var event = start_event;
    event.version = 2;
    try std.testing.expectError(error.MissingSessionTimezone, encode(std.testing.allocator, event));
    for ([_][]const u8{ "", "Not/A_Zone" }) |name| {
        event.change.start.time_zone = name;
        try std.testing.expectError(error.InvalidTimeZone, encode(std.testing.allocator, event));
    }
    event.version = 1;
    event.change.start.time_zone = "UTC";
    try std.testing.expectError(error.UnexpectedSessionTimezone, encode(std.testing.allocator, event));
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
    const future = "{\"version\":3,\"change\":{\"start\":{\"session_id\":1,\"activity\":{\"id\":\"work\",\"name\":\"Work\"},\"start_utc_ns\":0}}}\n";
    try std.testing.expectError(error.UnsupportedHistoryVersion, History.replay(std.testing.allocator, future));
    var invalid = start_event;
    invalid.version = 3;
    try std.testing.expectError(error.UnsupportedHistoryVersion, replayEvents(&.{invalid}));
    invalid = start_event;
    invalid.change.start.activity.id = " ";
    try std.testing.expectError(error.InvalidActivity, replayEvents(&.{invalid}));
    invalid = start_event;
    invalid.change.start.session_id = 0;
    try std.testing.expectError(error.InvalidSessionId, replayEvents(&.{invalid}));
}
