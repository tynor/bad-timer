//! Single-owner, main-thread C bridge. Strings remain valid until close.
const std = @import("std");
const core = @import("bad_timer");
const allocator = std.heap.page_allocator;
const Context = struct {
    threaded: std.Io.Threaded,
    config: core.config.Config,
    store: core.storage.Store,
    live: core.Timer = .{},
    zone: core.time_zone.Zone,
    totals: ?[:0]u8 = null,
    totals_day: i64 = 0,
    totals_elapsed: u64 = 0,
    totals_dirty: bool = true,
};
var context: ?*Context = null;
var last_error: [:0]const u8 = "";
fn failed(err: anyerror) c_int {
    last_error = @errorName(err);
    return -1;
}
export fn bt_error() [*:0]const u8 {
    return last_error.ptr;
}
export fn bt_open(config_path: [*:0]const u8, history_path: [*:0]const u8) c_int {
    open(std.mem.span(config_path), std.mem.span(history_path)) catch |err| return failed(err);
    return 0;
}
fn open(config_path: []const u8, history_path: []const u8) !void {
    if (context != null) return error.AlreadyOpen;
    const ctx = try allocator.create(Context);
    errdefer allocator.destroy(ctx);
    ctx.threaded = std.Io.Threaded.init(allocator, .{});
    errdefer ctx.threaded.deinit();
    ctx.config = try core.config.Config.load(allocator, ctx.threaded.io(), config_path);
    errdefer ctx.config.deinit();
    ctx.store = try core.storage.Store.open(allocator, ctx.threaded.io(), history_path);
    errdefer ctx.store.deinit(ctx.threaded.io());
    // Recovery remains explicit in the TUI; opening here must not mutate unfinished logs.
    if (ctx.store.history.unfinished != null) return error.UnfinishedSessionUseTUIRecovery;
    try ctx.store.assignLegacyTimezone(ctx.threaded.io(), ctx.config.timeZone());
    ctx.zone = try core.time_zone.Zone.init(ctx.config.timeZone());
    ctx.live = .{};
    ctx.totals = null;
    ctx.totals_dirty = true;
    context = ctx;
}
export fn bt_count() usize {
    return if (context) |ctx| ctx.config.activities().len else 0;
}
export fn bt_name(index: usize, buffer: [*]u8, capacity: usize) usize {
    const ctx = context orelse return 0;
    if (index >= ctx.config.activities().len) return 0;
    const name = ctx.config.activities()[index].name;
    if (capacity > name.len) {
        @memcpy(buffer[0..name.len], name);
        buffer[name.len] = 0;
    }
    return name.len + 1;
}
export fn bt_running() isize {
    const ctx = context orelse return -1;
    const running = ctx.live.running orelse return -1;
    for (ctx.config.activities(), 0..) |activity, index| {
        if (std.mem.eql(u8, activity.id, running.activity.id)) return @intCast(index);
    }
    return -1;
}
export fn bt_elapsed(seconds: *u64) c_int {
    const ctx = context orelse return failed(error.NotOpen);
    const now = core.clock.now() catch |err| return failed(err);
    const ns = ctx.live.elapsed(now) catch |err| return failed(err);
    seconds.* = ns / std.time.ns_per_s;
    return 0;
}
export fn bt_select(index: isize) c_int {
    const ctx = context orelse return failed(error.NotOpen);
    if (index < -1 or index >= @as(isize, @intCast(ctx.config.activities().len))) return failed(error.InvalidActivity);
    const activity = if (index == -1) null else ctx.config.activities()[@intCast(index)];
    core.transition(&ctx.live, &ctx.store, ctx.threaded.io(), ctx.config, activity, "history") catch |err| return failed(err);
    ctx.totals_dirty = true;
    return 0;
}
// Borrowed JSON, valid until the next successful refresh or close. Failure leaves the old snapshot intact.
export fn bt_totals() ?[*:0]const u8 {
    const ctx = context orelse {
        _ = failed(error.NotOpen);
        return null;
    };
    return refreshTotals(ctx) catch |err| {
        _ = failed(err);
        return null;
    };
}
fn refreshTotals(ctx: *Context) ![*:0]const u8 {
    const now = try core.clock.now();
    const seconds = std.math.cast(i64, @divFloor(now.utc_ns, std.time.ns_per_s)) orelse return error.TimestampOutOfRange;
    const day = (try ctx.zone.dayAt(seconds)).start_utc_seconds;
    const elapsed = (try ctx.live.elapsed(now)) / std.time.ns_per_s;
    if (ctx.totals != null and !ctx.totals_dirty and ctx.totals_day == day and ctx.totals_elapsed == elapsed) return ctx.totals.?.ptr;
    const json = try core.native_totals.snapshot(allocator, ctx.config, ctx.zone, ctx.store.history.sessions.items, ctx.live, now);
    if (ctx.totals) |previous| allocator.free(previous);
    ctx.totals = json;
    ctx.totals_day = day;
    ctx.totals_elapsed = elapsed;
    ctx.totals_dirty = false;
    return json.ptr;
}
// Closing never silently abandons a running session; callers stop durably first.
export fn bt_close() c_int {
    const ctx = context orelse return 0;
    if (ctx.live.running != null and !ctx.store.write_failed) return failed(error.TimerStillRunning);
    if (ctx.totals) |json| allocator.free(json);
    ctx.zone.deinit();
    ctx.store.deinit(ctx.threaded.io());
    ctx.config.deinit();
    ctx.threaded.deinit();
    allocator.destroy(ctx);
    context = null;
    return 0;
}
