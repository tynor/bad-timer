//! Shared durable transitions for terminal and native frontends.
const std = @import("std");
const timer = @import("root.zig");
const Config = timer.config.Config;

pub fn transition(live: *timer.Timer, store: *timer.storage.Store, io: std.Io, config: Config, activity: ?timer.Activity, path: []const u8) !void {
    const allocator = store.history.arena.child_allocator;
    const starts = if (activity) |selected| (if (live.running) |running| !std.mem.eql(u8, selected.id, running.activity.id) else true) else false;
    const name = if (starts) try config.sessionTimeZone(allocator) else null;
    defer if (name) |value| allocator.free(value);
    const now = try timer.clock.now();
    var next = live.*;
    const completed = if (activity) |selected| try next.select(selected, now) else try next.stop(now);
    const stop: ?timer.history.Stop = if (completed) |session| .{
        .session_id = store.history.unfinished.?.session_id,
        .activity = session.activity,
        .end_utc_ns = session.end_utc_ns,
        .duration_ns = session.duration_ns,
    } else null;
    const start: ?timer.history.Start = if (next.running) |running| .{
        .session_id = try std.math.add(u64, store.history.last_session_id, 1),
        .activity = running.activity,
        .start_utc_ns = running.start.utc_ns,
        .time_zone = name,
    } else null;
    const event: timer.history.Event = .{ .version = 2, .change = if (start) |s|
        (if (stop) |t| .{ .switch_activity = .{ .start = s, .stop = t } } else .{ .start = s })
    else if (stop) |t| .{ .stop = t } else return };
    store.append(io, event) catch |err| {
        std.debug.print("bad_timer: timer save failed at {s}: {s}; disk may contain part or all of the event; preserve the history file and restart to inspect it; do not retry in this process\n", .{ path, @errorName(err) });
        return error.TimerSaveFailed;
    };
    if (next.running) |*running| running.time_zone = store.history.unfinished.?.time_zone;
    live.* = next;
}
