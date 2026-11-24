const std = @import("std");
const builtin = @import("builtin");
const c = @import("terminal_c");
const timer = @import("bad_timer");
const Config = timer.config.Config;

test {
    _ = @import("recovery.zig");
}

const RecoveryMode = enum { choice, entry, confirm };

var stopping = std.atomic.Value(bool).init(false);
var resized = std.atomic.Value(bool).init(false);

fn onSignal(sig: c_int) callconv(.c) void {
    if (sig == c.SIGWINCH) resized.store(true, .monotonic) else stopping.store(true, .monotonic);
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("bad_timer: {s}\n", .{@errorName(err)});
        if (err == error.InvalidArguments)
            std.debug.print("usage: bad_timer [--config PATH] [--history PATH]\n       bad_timer --recover-history SOURCE DESTINATION\n", .{});
        std.process.exit(1);
    };
}

fn output(text: []const u8) !void {
    var remaining = text;
    while (remaining.len != 0) {
        const n = c.write(c.STDOUT_FILENO, remaining.ptr, remaining.len);
        if (n < 0) {
            if (c.__error().* == c.EINTR) continue;
            return error.TerminalWriteFailed;
        }
        if (n == 0) return error.TerminalWriteFailed;
        remaining = remaining[@intCast(n)..];
    }
}

const Paths = struct {
    config: []u8,
    history: []u8,
};

fn paths(init: std.process.Init) !Paths {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    var config: ?[]const u8 = null;
    var history: ?[]const u8 = null;
    while (args.next()) |flag| {
        const target = if (std.mem.eql(u8, flag, "--config")) &config else if (std.mem.eql(u8, flag, "--history")) &history else return error.InvalidArguments;
        if (target.* != null) return error.InvalidArguments;
        const path = args.next() orelse return error.InvalidArguments;
        if (path.len == 0 or std.mem.startsWith(u8, path, "--")) return error.InvalidArguments;
        target.* = path;
    }
    const config_path = try resolvePath(init.gpa, config, "config.json");
    errdefer init.gpa.free(config_path);
    return .{ .config = config_path, .history = try resolvePath(init.gpa, history, "history.jsonl") };
}

fn resolvePath(allocator: std.mem.Allocator, override: ?[]const u8, filename: []const u8) ![]u8 {
    if (override) |path| return allocator.dupe(u8, path);
    const home = c.getenv("HOME") orelse return error.MissingHomeDirectory;
    if (!std.fs.path.isAbsolute(std.mem.span(home))) return error.InvalidHomeDirectory;
    return std.fs.path.join(allocator, &.{ std.mem.span(home), "Library/Application Support/bad-timer", filename });
}

// Recovery deliberately bypasses config loading and all raw/alternate-screen setup.
fn recoverHistory(init: std.process.Init) !bool {
    var args = init.minimal.args.iterate();
    _ = args.skip();
    const flag = args.next() orelse return false;
    if (!std.mem.eql(u8, flag, "--recover-history")) return false;
    const source = args.next() orelse return error.InvalidArguments;
    const destination = args.next() orelse return error.InvalidArguments;
    if (source.len == 0 or destination.len == 0 or
        std.mem.startsWith(u8, source, "--") or std.mem.startsWith(u8, destination, "--") or args.next() != null)
        return error.InvalidArguments;
    if (builtin.os.tag != .macos) return error.RequiresMacOS;
    if (c.isatty(c.STDIN_FILENO) != 1) return error.RequiresInteractiveTTY;
    try output("Incomplete-tail recovery\nSource (kept as backup): ");
    try activityName(source);
    try output("\nNew destination: ");
    try activityName(destination);
    try output("\nWARNING: all bytes after the last LF will be omitted, even valid JSON.\nThey may contain a real time transition; this is not lossless repair.\nComplete-record corruption is rejected. Neither file will be activated automatically.\nKeep the original source. Type yes and Enter to create the separate file; anything else cancels: ");
    var answer: [4]u8 = undefined;
    var length: usize = 0;
    while (length < answer.len) {
        const n = c.read(c.STDIN_FILENO, answer[length..].ptr, 1);
        if (n < 0) {
            if (c.__error().* == c.EINTR) continue;
            return error.TerminalReadFailed;
        }
        if (n == 0) break;
        length += 1;
        if (answer[length - 1] == '\n') break;
    }
    if (!std.mem.eql(u8, answer[0..length], "yes\n")) {
        try output("Cancelled; no files changed.\n");
        return true;
    }
    const report = timer.history_recovery.recover(init.gpa, init.io, .cwd(), source, destination) catch |err| {
        std.debug.print("bad_timer: recovery failed: {s}; preserve the source and inspect the destination before retrying; no history was activated\n", .{@errorName(err)});
        return error.HistoryRecoveryFailed;
    };
    var buffer: [256]u8 = undefined;
    try output(try std.fmt.bufPrint(&buffer, "Published separate history: retained {d} bytes; omitted {d} uncertain bytes; completed sessions: {d}.\n", .{ report.retained_bytes, report.omitted_bytes, report.completed_sessions }));
    if (report.unfinished_session_id) |id| {
        try output(try std.fmt.bufPrint(&buffer, "Unfinished session {d}: still requires explicit end-time/duration/discard recovery.\n", .{id}));
    } else try output("No unfinished session remains in the retained prefix.\n");
    try output("Source preserved as backup; keep it. Neither file was activated automatically.\n");
    return true;
}

fn run(init: std.process.Init) !void {
    if (try recoverHistory(init)) return;
    const allocator = init.gpa;
    const locations = try paths(init);
    defer allocator.free(locations.config);
    defer allocator.free(locations.history);
    const config_path = locations.config;
    if (builtin.os.tag != .macos) return error.RequiresMacOS;
    if (c.isatty(c.STDIN_FILENO) != 1 or c.isatty(c.STDOUT_FILENO) != 1)
        return error.RequiresInteractiveTTY;
    const term = c.getenv("TERM") orelse return error.RequiresGhostty;
    if (!std.mem.eql(u8, std.mem.span(term), "xterm-ghostty")) return error.RequiresGhostty;

    var config = Config.load(allocator, init.io, config_path) catch |err| {
        std.debug.print("bad_timer: cannot load config at {s}: {s}; create or fix this JSON file (see README.md)\n", .{ config_path, @errorName(err) });
        return error.ConfigLoadFailed;
    };
    defer config.deinit();
    var zone = try timer.time_zone.Zone.init(config.timeZone());
    defer zone.deinit();

    var store = @import("bad_timer").storage.Store.open(allocator, init.io, locations.history) catch |err| {
        std.debug.print("bad_timer: cannot load history at {s}: {s}; ensure its parent directory exists and no other timer is using it; preserve corrupt files for recovery\n", .{ locations.history, @errorName(err) });
        return error.HistoryLoadFailed;
    };
    defer store.deinit(init.io);

    var original: c.struct_termios = undefined;
    if (c.tcgetattr(c.STDIN_FILENO, &original) != 0) return error.TerminalSetupFailed;

    const signals = [_]c_int{ c.SIGINT, c.SIGTERM, c.SIGHUP, c.SIGQUIT, c.SIGWINCH };
    var previous: [signals.len]c.struct_sigaction = undefined;
    var installed: usize = 0;
    defer for (signals[0..installed], previous[0..installed]) |sig, *action| {
        _ = c.sigaction(sig, action, null);
    };
    for (signals, &previous) |sig, *old| {
        var action = std.mem.zeroes(c.struct_sigaction);
        action.__sigaction_u.__sa_handler = onSignal;
        _ = c.sigemptyset(&action.sa_mask);
        if (c.sigaction(sig, &action, old) != 0) return error.SignalSetupFailed;
        installed += 1;
    }

    var raw = original;
    c.cfmakeraw(&raw);
    // Keep Ctrl-C as a signal, but disable job-control suspension in raw mode.
    raw.c_lflag |= c.ISIG;
    raw.c_cc[c.VSUSP] = c._POSIX_VDISABLE;
    raw.c_cc[c.VDSUSP] = c._POSIX_VDISABLE;
    if (c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &raw) != 0) return error.TerminalSetupFailed;
    defer {
        var result: c_int = undefined;
        while (true) {
            result = c.tcsetattr(c.STDIN_FILENO, c.TCSANOW, &original);
            if (result == 0 or c.__error().* != c.EINTR) break;
        }
        if (result != 0) std.debug.print("bad_timer: terminal restore failed; run stty sane\n", .{});
    }
    defer output("\x1b[?2026l\x1b[?7h\x1b[?25h\x1b[?1049l") catch {};
    try output("\x1b[?1049h\x1b[?25l");

    var recovery_mode: RecoveryMode = .choice;
    var recovery_visible = false;
    var duration_entry = false;
    var end_input: [256]u8 = undefined;
    var end_length: usize = 0;
    var input_overflow = false;
    var recovery_error = false;
    var recovered_end: i128 = 0;
    var recovered_duration: u64 = 0;
    var live: timer.Timer = .{};
    var last_second: u64 = 0;
    var last_day: ?i64 = null;
    var menu: ?usize = null;
    var summary: ?timer.summaries.Kind = null;
    var summary_scroll: usize = 0;
    var summary_max_scroll: usize = 0;
    var export_number: u64 = 1;
    var status_buffer: [256]u8 = undefined;
    var status: []const u8 = "";
    var dirty = true;
    while (!stopping.load(.monotonic)) {
        if (resized.swap(false, .monotonic)) dirty = true;
        const now = try timer.clock.now();
        const second = (try live.elapsed(now)) / std.time.ns_per_s;
        const utc_seconds = std.math.cast(i64, @divFloor(now.utc_ns, std.time.ns_per_s)) orelse return error.TimestampOutOfRange;
        const day = try zone.dayAt(utc_seconds);
        if (second != last_second or last_day != day.start_utc_seconds) dirty = true;
        last_second = second;
        last_day = day.start_utc_seconds;
        if (dirty) {
            // One boundary owns synchronized output and wrapping for every screen.
            errdefer output("\x1b[?2026l\x1b[?7h") catch {};
            try output("\x1b[?2026h\x1b[?7l");
            if (if (live.running == null) store.history.unfinished else null) |session| {
                recovery_visible = try drawRecovery(session, recovery_mode, duration_entry, end_input[0..end_length], recovery_error, recovered_end, recovered_duration);
            } else if (summary) |kind| {
                var report = try timer.summaries.calculate(allocator, zone, store.history.sessions.items, live, now, kind);
                defer report.deinit();
                summary_max_scroll = try drawSummary(config, kind, report, live.running != null, &summary_scroll);
            } else if (menu) |selected| {
                try drawMenu(config, selected, live);
            } else {
                const totals = try timer.totals.calculate(allocator, zone, store.history.sessions.items, live, now);
                defer allocator.free(totals);
                const weekly = try timer.totals.calculateWeek(allocator, zone, store.history.sessions.items, live, now);
                defer allocator.free(weekly);
                try draw(config, live, second, status, totals, weekly);
            }
            try output("\x1b[?2026l\x1b[?7h");
            dirty = false;
        }
        var readable: c.fd_set = std.mem.zeroes(c.fd_set);
        c.FD_SET(c.STDIN_FILENO, &readable);
        var timeout = c.struct_timeval{ .tv_sec = 1, .tv_usec = 0 };
        const ready = c.select(c.STDIN_FILENO + 1, &readable, null, null, &timeout);
        if (ready < 0) {
            if (c.__error().* == c.EINTR) continue;
            return error.TerminalWaitFailed;
        }
        if (ready == 0) continue;
        var key: u8 = undefined;
        const n = c.read(c.STDIN_FILENO, &key, 1);
        if (n < 0) {
            if (c.__error().* == c.EINTR) continue;
            return error.TerminalReadFailed;
        }
        if (n == 0) return error.TerminalDisconnected;
        if (key == 'q') break;
        if (if (live.running == null) store.history.unfinished else null) |session| {
            if (key == 27) {
                recovery_mode = .choice;
                end_length = 0;
                input_overflow = false;
                recovery_error = false;
            } else if (recovery_mode == .entry) {
                if (key == '\r' or key == '\n') {
                    const recovery = @import("recovery.zig");
                    if (input_overflow) {
                        recovery_error = true;
                        dirty = true;
                        continue;
                    }
                    const parsed = if (duration_entry) recovery.duration(end_input[0..end_length], session.start_utc_ns) else recovery.endTime(end_input[0..end_length], session.start_utc_ns);
                    if (parsed) |result| {
                        recovered_end = result.end_ns;
                        recovered_duration = result.duration_ns;
                        recovery_mode = .confirm;
                    } else |_| {
                        recovery_error = true;
                    }
                } else if (key == 127 or key == 8) {
                    end_length -|= 1;
                    recovery_error = false;
                } else if (key >= 32 and key != 127) {
                    if (end_length < end_input.len) {
                        end_input[end_length] = key;
                        end_length += 1;
                    } else {
                        input_overflow = true;
                        recovery_error = true;
                    }
                }
            } else if (recovery_mode == .confirm) {
                if (key == 'y' and recovery_visible) {
                    store.append(init.io, .{ .version = 1, .change = .{ .stop = .{
                        .session_id = session.session_id,
                        .activity = session.activity,
                        .end_utc_ns = recovered_end,
                        .duration_ns = recovered_duration,
                    } } }) catch |err| {
                        std.debug.print("bad_timer: recovery failed at {s}: {s}; disk may contain part or all of the event; preserve the history file and restart to inspect it; do not retry in this process\n", .{ locations.history, @errorName(err) });
                        return error.HistoryRecoveryFailed;
                    };
                }
            } else if (key == 't' or key == 'u') {
                duration_entry = key == 'u';
                recovery_mode = .entry;
                end_length = 0;
                input_overflow = false;
                recovery_error = false;
            } else if (key == 'd') {
                store.append(init.io, .{ .version = 1, .change = .{ .discard = .{ .session_id = session.session_id } } }) catch |err| {
                    std.debug.print("bad_timer: discard failed at {s}: {s}; disk may contain part or all of the event; preserve the history file and restart to inspect it; do not retry in this process\n", .{ locations.history, @errorName(err) });
                    return error.HistoryDiscardFailed;
                };
            }
            dirty = true;
            continue;
        }
        if (summary != null) {
            if (key == 27) {
                const arrow = try escapeKey();
                if (arrow == null) summary = null else if (arrow.? == 'A') {
                    summary_scroll -|= 1;
                } else if (arrow.? == 'B') summary_scroll = @min(summary_scroll +| 1, summary_max_scroll);
            }
            dirty = true;
            continue;
        }
        if (menu) |selected| {
            if (key == 27) {
                const arrow = try escapeKey();
                if (arrow == null) {
                    menu = null;
                } else if (arrow.? == 'A') {
                    menu = selected -| 1;
                } else if (arrow.? == 'B') {
                    menu = @min(selected + 1, config.activities().len - 1);
                }
            } else if (key == '\r' or key == '\n') {
                try transition(&live, &store, init.io, config.activities()[selected], locations.history);
                menu = null;
            }
            dirty = true;
            continue;
        }
        if (key == 27) {
            _ = try escapeKey();
            continue;
        }
        if (key == 'e') {
            var path_buffer: [80]u8 = undefined;
            const path = exportReport(allocator, init.io, store.history.sessions.items, &export_number, &path_buffer) catch |err| {
                status = try std.fmt.bufPrint(&status_buffer, "Export failed: {s}; check current directory permissions and disk space; history unchanged.", .{@errorName(err)});
                dirty = true;
                continue;
            };
            status = try std.fmt.bufPrint(&status_buffer, "Exported completed sessions to ./{s}", .{path});
        }
        if (key == 'a') menu = 0;
        if (key == 'd' or key == 'w') {
            summary = if (key == 'd') .daily else .weekly;
            summary_scroll = 0;
        }
        if (key >= '1' and key <= '9') {
            const index: usize = key - '1';
            if (index < config.activities().len)
                try transition(&live, &store, init.io, config.activities()[index], locations.history);
        }
        dirty = true;
    }
    if (live.running != null) try transition(&live, &store, init.io, null, locations.history);
}

fn exportReport(allocator: std.mem.Allocator, io: std.Io, sessions: []const timer.Session, number: *u64, buffer: []u8) ![]const u8 {
    while (true) {
        const path = try std.fmt.bufPrint(buffer, "bad-timer-{d}.csv", .{number.*});
        timer.csv.publish(allocator, io, .cwd(), path, sessions) catch |err| {
            if (err == error.PathAlreadyExists) {
                number.* = try std.math.add(u64, number.*, 1);
                continue;
            }
            return err;
        };
        return path;
    }
}

fn transition(live: *timer.Timer, store: *timer.storage.Store, io: std.Io, activity: ?timer.Activity, path: []const u8) !void {
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
    } else null;
    const event: timer.history.Event = .{ .version = 1, .change = if (start) |s|
        (if (stop) |t| .{ .switch_activity = .{ .start = s, .stop = t } } else .{ .start = s })
    else if (stop) |t| .{ .stop = t } else return };
    store.append(io, event) catch |err| {
        std.debug.print("bad_timer: timer save failed at {s}: {s}; disk may contain part or all of the event; preserve the history file and restart to inspect it; do not retry in this process\n", .{ path, @errorName(err) });
        return error.TimerSaveFailed;
    };
    live.* = next;
}

// Bound escape-sequence reads so a standalone Escape cancels without waiting a second.
fn escapeKey() !?u8 {
    var prefix: u8 = 0;
    for (0..16) |index| {
        var readable: c.fd_set = std.mem.zeroes(c.fd_set);
        c.FD_SET(c.STDIN_FILENO, &readable);
        var timeout = c.struct_timeval{ .tv_sec = 0, .tv_usec = 50000 };
        const ready = c.select(c.STDIN_FILENO + 1, &readable, null, null, &timeout);
        if (ready < 0) {
            if (c.__error().* == c.EINTR) return null;
            return error.TerminalWaitFailed;
        }
        if (ready == 0) return null;
        var byte: u8 = undefined;
        const count = c.read(c.STDIN_FILENO, &byte, 1);
        if (count == 0) return error.TerminalDisconnected;
        if (count < 0) return error.TerminalReadFailed;
        if (index == 0) {
            prefix = byte;
            if (prefix != '[' and prefix != 'O') return null;
        } else if (byte >= 0x40 and byte <= 0x7e) {
            return if (index == 1) byte else 0;
        }
    }
    return 0;
}

fn utcText(ns: i128, buffer: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    timer.csv.timestamp(&writer, ns) catch |err| switch (err) {
        error.TimestampOutOfRange => return "outside supported UTC range (years 1-9999)",
        else => return err,
    };
    return writer.buffered();
}

fn drawRecovery(session: timer.history.Start, mode: RecoveryMode, duration_entry: bool, input: []const u8, invalid: bool, end: i128, elapsed: u64) !bool {
    var size: c.struct_winsize = std.mem.zeroes(c.struct_winsize);
    if (c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &size) != 0) return error.TerminalSizeFailed;
    try output("\x1b[H\x1b[2J");
    const rows: usize = @max(size.ws_row, 1);
    var screen = Screen{ .rows = rows - 1 };
    var buffer: [256]u8 = undefined;
    if (try screen.line()) try output(try std.fmt.bufPrint(&buffer, "Recovery | Unfinished session {d}", .{session.session_id}));
    if (try screen.line()) {
        try output("Activity: ");
        try activityName(session.activity.name);
    }
    if (try screen.line()) {
        try output("Start UTC: ");
        try output(try utcText(session.start_utc_ns, &buffer));
    }
    if (try screen.line()) try output("No time will be counted automatically.");
    switch (mode) {
        .choice => {
            if (try screen.line()) try output("d: discard unfinished session (adds no time)");
            if (try screen.line()) try output("t: supply UTC end time");
            if (try screen.line()) try output("u: supply duration (Go format)");
        },
        .entry => {
            if (try screen.line()) try output(if (duration_entry) "Duration (e.g. 1h30m, 2.5h, 300ms):" else "End UTC (YYYY-MM-DDTHH:MM:SSZ):");
            if (try screen.line()) try activityName(input);
            if (invalid and try screen.line()) try output(if (duration_entry) "Invalid duration, negative result, or input/value exceeds range." else "Invalid end time, before start, or input/duration exceeds range.");
        },
        .confirm => {
            if (try screen.line()) try output(if (duration_entry) "Duration supplied by you; not measured elapsed time." else "Based on wall-clock timestamps, not measured elapsed time.");
            if (try screen.line()) {
                try output("End UTC: ");
                try output(try utcText(end, &buffer));
            }
            if (try screen.line()) {
                try output("Recovery duration: ");
                try output(try duration(&buffer, elapsed / std.time.ns_per_s));
                try output(try std.fmt.bufPrint(&buffer, ".{d:0>9}", .{elapsed % std.time.ns_per_s}));
            }
            if (duration_entry and try screen.line()) {
                try output("Supplied duration: ");
                try activityName(input);
            }
        },
    }
    const visible = rows >= 10 and size.ws_col >= 60;
    if ((screen.clipped or (mode == .confirm and !visible)) and screen.rows > 0)
        try output(try std.fmt.bufPrint(&buffer, "\x1b[{d};1H\x1b[2KEnlarge terminal to review (60x10)", .{screen.rows}));
    try output(try std.fmt.bufPrint(&buffer, "\x1b[{d};1H", .{rows}));
    try output(if (mode == .confirm and visible) "y: confirm and save; Esc: cancel | q: quit" else if (size.ws_col < 40) "Esc: back | q: quit" else if (mode == .entry) "Enter: review; Esc: cancel | q: quit" else "q / Ctrl-C: exit without changing history");
    return visible;
}

test "recovery UTC display preserves fractions and handles unsupported dates" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("1969-12-31T23:59:59.999999999Z", try utcText(-1, &buffer));
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.002501100Z", try utcText(2501100, &buffer));
    try std.testing.expectEqualStrings("outside supported UTC range (years 1-9999)", try utcText(std.math.maxInt(i128), &buffer));
}

fn drawMenu(config: Config, selected: usize, live: timer.Timer) !void {
    var size: c.struct_winsize = std.mem.zeroes(c.struct_winsize);
    if (c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &size) != 0) return error.TerminalSizeFailed;
    try output("\x1b[H\x1b[2J");
    const rows: usize = @max(size.ws_row, 1);
    const header = rows >= 3;
    const footer = rows >= 2;
    const capacity = rows - @intFromBool(header) - @intFromBool(footer);
    const first = selected -| (capacity - 1);
    const end = @min(first + capacity, config.activities().len);
    var screen = Screen{ .rows = rows };
    var buffer: [80]u8 = undefined;
    if (header and try screen.line())
        try output(try std.fmt.bufPrint(&buffer, "Activities {d}/{d} | ^{d} v{d}", .{ selected + 1, config.activities().len, first, config.activities().len - end }));
    for (first..end) |index| {
        _ = try screen.line();
        try output(if (index == selected) "> " else "  ");
        if (!header) try output(try std.fmt.bufPrint(&buffer, "{d}/{d} ", .{ selected + 1, config.activities().len }));
        try output(&.{ config.numericKey(index) orelse '-', ' ', ' ' });
        const activity = config.activities()[index];
        if (live.running) |running| {
            if (std.mem.eql(u8, running.activity.id, activity.id)) try output("[running] ");
        }
        try activityName(activity.name);
    }
    if (footer) {
        try output(try std.fmt.bufPrint(&buffer, "\x1b[{d};1H", .{rows}));
        try output(if (size.ws_col >= 44) "Up/Down: move | Enter: toggle | Esc: back" else if (size.ws_col >= 24) "Up/Down Enter Esc: back" else "^v Ent Esc");
    }
}

fn activityName(name: []const u8) !void {
    // Config names are data, not terminal control sequences.
    var buffer: [256]u8 = undefined;
    var offset: usize = 0;
    while (offset < name.len) {
        const length = @min(buffer.len, name.len - offset);
        for (name[offset..][0..length], buffer[0..length]) |byte, *dest|
            dest.* = if (byte < 32 or byte == 127) '?' else byte;
        try output(buffer[0..length]);
        offset += length;
    }
}

// Address rows explicitly and disable wrapping: names must never scroll controls away.
const Screen = struct {
    rows: usize,
    row: usize = 0,
    clipped: bool = false,

    fn line(self: *Screen) !bool {
        if (self.row >= self.rows) {
            self.clipped = true;
            return false;
        }
        self.row += 1;
        var buffer: [40]u8 = undefined;
        try output(try std.fmt.bufPrint(&buffer, "\x1b[{d};1H", .{self.row}));
        return true;
    }
};

fn duration(buffer: []u8, seconds: u128) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}:{d:0>2}", .{ seconds / 3600, seconds / 60 % 60, seconds % 60 });
}

fn totalSeconds(totals: []const timer.totals.Total, id: []const u8) u128 {
    for (totals) |total| {
        if (std.mem.eql(u8, total.activity.id, id)) return total.duration_ns / std.time.ns_per_s;
    }
    return 0;
}

fn activityRow(screen: *Screen, key: ?u8, activity: timer.Activity, active: bool, seconds: u128, week: ?u128) !void {
    if (!try screen.line()) return;
    var buffer: [80]u8 = undefined;
    try output(&.{ if (active) '>' else ' ', ' ', key orelse '-', ' ', ' ' });
    try output(try duration(&buffer, seconds));
    if (week) |value| {
        try output("  ");
        try output(try duration(&buffer, value));
    }
    try output("  ");
    try activityName(activity.name);
}

test "display durations keep hours beyond one day and do not wrap" {
    var buffer: [80]u8 = undefined;
    try std.testing.expectEqualStrings("00:00:00", try duration(&buffer, 0));
    try std.testing.expectEqualStrings("01:02:03", try duration(&buffer, 3723));
    try std.testing.expectEqualStrings("100:00:01", try duration(&buffer, 360001));
    _ = try duration(&buffer, std.math.maxInt(u128) / std.time.ns_per_s);
}

fn dateText(buffer: []u8, date: timer.time_zone.Date) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u16, @intCast(date.year)), @as(u8, @intCast(date.month)), @as(u8, @intCast(date.day)) });
}

fn summaryLine(screen: *Screen, index: *usize, skip: usize) !bool {
    const current = index.*;
    index.* += 1;
    return current >= skip and try screen.line();
}

fn drawSummary(config: Config, kind: timer.summaries.Kind, report: timer.summaries.Report, running: bool, scroll: *usize) !usize {
    var size: c.struct_winsize = std.mem.zeroes(c.struct_winsize);
    if (c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &size) != 0) return error.TerminalSizeFailed;
    try output("\x1b[H\x1b[2J");
    const rows: usize = @max(size.ws_row, 1);
    const header = rows >= 3;
    const footer = rows >= 2;
    const capacity = rows - @intFromBool(header) - @intFromBool(footer);
    var count: usize = 0;
    for (report.periods) |period| count += 1 + @max(period.totals.len, 1);
    const maximum = count -| capacity;
    scroll.* = @min(scroll.*, maximum);
    var screen = Screen{ .rows = rows - @intFromBool(footer) };
    var buffer: [256]u8 = undefined;
    if (header and try screen.line()) {
        try output(if (kind == .daily) "Daily summaries | " else "Weekly summaries | ");
        try activityName(config.timeZone());
        try output(try std.fmt.bufPrint(&buffer, " | ^{d} v{d}", .{ scroll.*, count - @min(scroll.* + capacity, count) }));
    }
    var line: usize = 0;
    for (report.periods, 0..) |period, period_index| {
        if (try summaryLine(&screen, &line, scroll.*)) {
            try output(try dateText(&buffer, period.first));
            if (kind == .weekly) {
                try output("..");
                try output(try dateText(&buffer, period.last));
            }
            try output(" | ");
            try output(try duration(&buffer, period.duration_ns / std.time.ns_per_s));
            if (period_index == 0) try output(if (running) " (current, in progress)" else " (current)");
        }
        if (period.totals.len == 0 and try summaryLine(&screen, &line, scroll.*)) try output("  No time recorded");
        for (period.totals) |total| {
            if (try summaryLine(&screen, &line, scroll.*)) {
                try output("  ");
                try output(try duration(&buffer, total.duration_ns / std.time.ns_per_s));
                try output("  ");
                var name = total.activity.name;
                for (config.activities()) |activity| {
                    if (std.mem.eql(u8, activity.id, total.activity.id)) {
                        name = activity.name;
                        break;
                    }
                }
                try activityName(name);
            }
        }
    }
    if (footer) {
        try output(try std.fmt.bufPrint(&buffer, "\x1b[{d};1H", .{rows}));
        try output(if (size.ws_col >= 40) "Up/Down: scroll | Esc: timer | q: quit" else "^v scroll Esc q");
    }
    return maximum;
}

fn draw(config: Config, live: timer.Timer, seconds: u64, status: []const u8, totals: []const timer.totals.Total, weekly: []const timer.totals.Total) !void {
    var size: c.struct_winsize = std.mem.zeroes(c.struct_winsize);
    if (c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &size) != 0) return error.TerminalSizeFailed;
    try output("\x1b[H\x1b[2J");
    const rows: usize = @max(size.ws_row, 1);
    const show_week = size.ws_col >= 50;
    const status_rows: usize = @intFromBool(status.len != 0 and rows > 1);
    var screen = Screen{ .rows = rows - 1 - status_rows };
    var buffer: [256]u8 = undefined;
    if (rows >= 8 and try screen.line()) {
        try output("bad-timer | ");
        try activityName(config.timeZone());
    }
    if (try screen.line()) {
        try output(if (live.running != null) "Active: " else "Stopped");
        if (live.running) |running| try activityName(running.activity.name);
    }
    if (try screen.line()) {
        try output("Elapsed: ");
        try output(try duration(&buffer, seconds));
    }
    if (rows >= 8) {
        _ = try screen.line();
        if (try screen.line()) try output(if (show_week) "Key  Today     This week  Activity (> running)" else "Key  Today     Activity (week: enlarge)");
    }
    for (config.activities(), 0..) |activity, index| {
        const active = if (live.running) |running| std.mem.eql(u8, running.activity.id, activity.id) else false;
        try activityRow(&screen, config.numericKey(index), activity, active, totalSeconds(totals, activity.id), if (show_week) totalSeconds(weekly, activity.id) else null);
    }
    for (weekly) |total| {
        for (config.activities()) |activity| {
            if (std.mem.eql(u8, activity.id, total.activity.id)) break;
        } else {
            try activityRow(&screen, null, total.activity, false, totalSeconds(totals, total.activity.id), if (show_week) total.duration_ns / std.time.ns_per_s else null);
        }
    }
    if (screen.clipped and screen.rows > 0) {
        try output(try std.fmt.bufPrint(&buffer, "\x1b[{d};1H\x1b[2KMore rows: enlarge terminal", .{screen.rows}));
    }
    if (status_rows != 0) {
        try output(try std.fmt.bufPrint(&buffer, "\x1b[{d};1H", .{rows - 1}));
        try activityName(status);
    }
    try output(try std.fmt.bufPrint(&buffer, "\x1b[{d};1H", .{rows}));
    try output(if (size.ws_col >= 66) "1-9: toggle | a: activities | d: days | w: weeks | e: export | q: quit" else if (size.ws_col >= 50) "1-9 toggle | a menu | d days w weeks | e csv q quit" else if (size.ws_col >= 25) "d days w weeks a menu e q" else if (size.ws_col >= 18) "d/w sums a menu q" else "a e q");
}
