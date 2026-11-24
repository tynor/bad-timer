//! Owned JSON configuration, loaded from a file or parsed in memory.
const std = @import("std");
const Activity = @import("root.zig").Activity;
const Zone = @import("time_zone.zig").Zone;

// Missing selects the system zone; a present null must still fail string parsing.
const ZoneName = struct {
    value: ?[]const u8 = null,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !ZoneName {
        return .{ .value = try std.json.innerParse([]const u8, allocator, source, options) };
    }
};

const Document = struct {
    activities: []const Activity,
    time_zone: ZoneName = .{},
};

/// Owns parsed strings and activities. Do not copy; borrowed values live until deinit.
pub const Config = struct {
    parsed: std.json.Parsed(Document),
    zone_name: []const u8,

    /// Reads only; never creates or modifies the config file.
    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
        const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
        defer allocator.free(source);
        return parse(allocator, source);
    }

    /// Copies input strings, so the caller may release the source after parsing.
    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Config {
        const parsed = try std.json.parseFromSlice(Document, allocator, source, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        const items = parsed.value.activities;
        if (items.len == 0) return error.NoActivities;
        for (items, 0..) |activity, index| {
            if (std.mem.trim(u8, activity.id, " \t\r\n").len == 0) return error.EmptyActivityId;
            if (std.mem.trim(u8, activity.name, " \t\r\n").len == 0) return error.BlankActivityName;
            for (items[0..index]) |previous| {
                if (std.mem.eql(u8, previous.id, activity.id)) return error.DuplicateActivityId;
            }
        }
        const zone_name = parsed.value.time_zone.value orelse try @import("time_zone.zig").systemName(parsed.arena.allocator());
        var zone = try Zone.init(zone_name);
        zone.deinit();
        return .{ .parsed = parsed, .zone_name = zone_name };
    }

    pub fn deinit(self: *Config) void {
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn activities(self: Config) []const Activity {
        return self.parsed.value.activities;
    }

    pub fn timeZone(self: Config) []const u8 {
        return self.zone_name;
    }

    /// Caller frees; omitted zones are resolved anew for each session start.
    pub fn sessionTimeZone(self: Config, allocator: std.mem.Allocator) ![]const u8 {
        return if (self.parsed.value.time_zone.value) |name| allocator.dupe(u8, name) else @import("time_zone.zig").systemName(allocator);
    }

    /// Only the first nine positions have numeric keys; all remain in menu order.
    pub fn numericKey(self: Config, index: usize) ?u8 {
        if (index >= self.activities().len or index >= 9) return null;
        return '1' + @as(u8, @intCast(index));
    }
};

test "config defaults, borrowed activities, and source ownership" {
    const source = try std.testing.allocator.dupe(u8,
        \\{"activities":[{"id":"work","name":"Work"},{"id":"rest","name":"Café \"break\""}]}
    );
    var config = Config.parse(std.testing.allocator, source) catch |err| {
        std.testing.allocator.free(source);
        return err;
    };
    defer config.deinit();
    std.testing.allocator.free(source);
    const expected_zone = try @import("time_zone.zig").systemName(std.testing.allocator);
    defer std.testing.allocator.free(expected_zone);
    try std.testing.expectEqualStrings(expected_zone, config.timeZone());
    const session_zone = try config.sessionTimeZone(std.testing.allocator);
    defer std.testing.allocator.free(session_zone);
    try std.testing.expectEqualStrings(expected_zone, session_zone);
    try std.testing.expectEqualStrings("work", config.activities()[0].id);
    try std.testing.expectEqualStrings("Café \"break\"", config.activities()[1].name);
    try std.testing.expectEqual(@as(?u8, '1'), config.numericKey(0));
    try std.testing.expectEqual(@as(?u8, '2'), config.numericKey(1));
    try std.testing.expectEqual(null, config.numericKey(2));
    try std.testing.expectEqual(null, config.numericKey(std.math.maxInt(usize)));
}

test "explicit UTC overrides the system default" {
    var config = try Config.parse(std.testing.allocator,
        \\{"time_zone":"UTC","activities":[{"id":"work","name":"Work"}]}
    );
    defer config.deinit();
    try std.testing.expectEqualStrings("UTC", config.timeZone());
    const session_zone = try config.sessionTimeZone(std.testing.allocator);
    defer std.testing.allocator.free(session_zone);
    try std.testing.expectEqualStrings("UTC", session_zone);
}

test "config rejects invalid activity identities and names" {
    const cases = .{
        .{ error.NoActivities, "{\"activities\":[]}" },
        .{ error.EmptyActivityId, "{\"activities\":[{\"id\":\"\",\"name\":\"Work\"}]}" },
        .{ error.EmptyActivityId, "{\"activities\":[{\"id\":\" \\t\",\"name\":\"Work\"}]}" },
        .{ error.BlankActivityName, "{\"activities\":[{\"id\":\"work\",\"name\":\" \\r\\n\\t\"}]}" },
        .{ error.DuplicateActivityId, "{\"activities\":[{\"id\":\"work\",\"name\":\"Work\"},{\"id\":\"work\",\"name\":\"Renamed\"}]}" },
        .{ error.InvalidTimeZone, "{\"activities\":[{\"id\":\"w\",\"name\":\"W\"}],\"time_zone\":\"Not/A_Zone\"}" },
        .{ error.InvalidTimeZone, "{\"activities\":[{\"id\":\"w\",\"name\":\"W\"}],\"time_zone\":\"\"}" },
    };
    inline for (cases) |case| {
        try std.testing.expectError(case[0], Config.parse(std.testing.allocator, case[1]));
    }
}

test "config rejects malformed JSON and schema errors" {
    const items = "[{\"id\":\"w\",\"name\":\"Work\"}]";
    const sources = [_][]const u8{
        "{",                                                   "{}",                                "null",                                           "[]",                                                              "{\"activities\":null}",
        "{\"activities\":[{\"id\":1,\"name\":\"Work\"}]}",     "{\"activities\":[{\"id\":\"w\"}]}", "{\"activities\":" ++ items ++ ",\"typo\":true}", "{\"activities\":" ++ items ++ ",\"activities\":" ++ items ++ "}", "{\"activities\":" ++ items ++ "} trailing",
        "{\"activities\":" ++ items ++ ",\"time_zone\":null}",
    };
    for (sources) |source| {
        if (Config.parse(std.testing.allocator, source)) |value| {
            var config = value;
            config.deinit();
            return error.ExpectedParseFailure;
        } else |_| {}
    }
}

test "config preserves order beyond nine activities and accepts an IANA zone" {
    var config = try Config.parse(std.testing.allocator,
        \\{"time_zone":"America/Los_Angeles","activities":[
        \\{"id":"b","name":"Second"},{"id":"a","name":"First"},
        \\{"id":"c","name":"C"},{"id":"d","name":"D"},
        \\{"id":"e","name":"E"},{"id":"f","name":"F"},
        \\{"id":"g","name":"G"},{"id":"h","name":"H"},
        \\{"id":"i","name":"I"},{"id":"j","name":"J"}]}
    );
    defer config.deinit();
    try std.testing.expectEqualStrings("America/Los_Angeles", config.timeZone());
    try std.testing.expectEqual(@as(usize, 10), config.activities().len);
    try std.testing.expectEqualStrings("b", config.activities()[0].id);
    try std.testing.expectEqualStrings("a", config.activities()[1].id);
    for (0..9) |index| try std.testing.expectEqual(@as(?u8, '1' + @as(u8, @intCast(index))), config.numericKey(index));
    try std.testing.expectEqualStrings("j", config.activities()[9].id);
    try std.testing.expectEqual(null, config.numericKey(9));
}
