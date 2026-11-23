//! In-memory JSON configuration; no file loading or terminal integration.
const std = @import("std");
const Activity = @import("root.zig").Activity;
const Zone = @import("time_zone.zig").Zone;

const Document = struct {
    activities: []const Activity,
    time_zone: []const u8 = "UTC",
};

/// Owns parsed strings and activities. Do not copy; borrowed values live until deinit.
pub const Config = struct {
    parsed: std.json.Parsed(Document),

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
        var zone = try Zone.init(parsed.value.time_zone);
        zone.deinit();
        return .{ .parsed = parsed };
    }

    pub fn deinit(self: *Config) void {
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn activities(self: Config) []const Activity {
        return self.parsed.value.activities;
    }

    pub fn timeZone(self: Config) []const u8 {
        return self.parsed.value.time_zone;
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
    try std.testing.expectEqualStrings("UTC", config.timeZone());
    try std.testing.expectEqualStrings("work", config.activities()[0].id);
    try std.testing.expectEqualStrings("Café \"break\"", config.activities()[1].name);
    try std.testing.expectEqual(@as(?u8, '1'), config.numericKey(0));
    try std.testing.expectEqual(@as(?u8, '2'), config.numericKey(1));
    try std.testing.expectEqual(null, config.numericKey(2));
    try std.testing.expectEqual(null, config.numericKey(std.math.maxInt(usize)));
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
