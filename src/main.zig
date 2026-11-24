const std = @import("std");
const builtin = @import("builtin");
const c = @import("terminal_c");
const timer = @import("bad_timer");
const Config = timer.config.Config;

test {
    _ = @import("recovery.zig");
}

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
    defer output("\x1b[?25h\x1b[?1049l") catch {};
    try output("\x1b[?1049h\x1b[?25l");

    var recovery_mode: enum { choice, entry, confirm } = .choice;
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
            if (if (live.running == null) store.history.unfinished else null) |session| {
                var buffer: [768]u8 = undefined;
                try output(try std.fmt.bufPrint(&buffer, "\x1b[H\x1b[2JUnfinished session {d}\r\nNo time will be counted automatically.\r\nd: discard unfinished session (adds no time)\r\nt: supply UTC end time\r\nu: supply duration (Go format)\r\nq / Ctrl-C: exit without changing history\r\n", .{session.session_id}));
                switch (recovery_mode) {
                    .choice => {},
                    .entry => {
                        try output(if (duration_entry) "Duration (e.g. 1h30m, 2.5h, 300ms); Enter: review; Esc: cancel\r\n" else "End UTC (YYYY-MM-DDTHH:MM:SSZ); Enter: review; Esc: cancel\r\n");
                        try output(end_input[0..end_length]);
                        if (recovery_error) try output(if (duration_entry) "\r\nInvalid duration, negative result, or input/value exceeds range. Esc: restart.\r\n" else "\r\nInvalid end time, before start, or input/duration exceeds range. Esc: restart.\r\n");
                    },
                    .confirm => {
                        if (duration_entry) {
                            try output(try std.fmt.bufPrint(&buffer, "Supplied duration: {s}\r\nDerived end UTC (Unix nanoseconds): {d}\r\n", .{ end_input[0..end_length], recovered_end }));
                        } else {
                            try output(try std.fmt.bufPrint(&buffer, "End UTC: {s}\r\nBased on wall-clock timestamps, not measured elapsed time.\r\n", .{end_input[0..end_length]}));
                        }
                        try output(try std.fmt.bufPrint(&buffer, "Recovery duration: {d} seconds + {d} ns\r\ny: confirm and save; Esc: cancel\r\n", .{ recovered_duration / std.time.ns_per_s, recovered_duration % std.time.ns_per_s }));
                    },
                }
            } else if (menu) |selected| {
                try drawMenu(config, selected);
            } else {
                const totals = try timer.totals.calculate(allocator, zone, store.history.sessions.items, live, now);
                defer allocator.free(totals);
                try draw(config, live, second, status, totals);
            }
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
                if (key == 'y') {
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

fn drawMenu(config: Config, selected: usize) !void {
    var size: c.struct_winsize = std.mem.zeroes(c.struct_winsize);
    if (c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &size) != 0) return error.TerminalSizeFailed;
    // Disable wrapping so long or wide Unicode names cannot push the selection off screen.
    try output("\x1b[H\x1b[2J\x1b[?7l");
    defer output("\x1b[?7h") catch {};
    const rows: usize = @max(size.ws_row, 1);
    if (rows > 1) try output("Activities: Up/Down, Enter: select, Esc: cancel\r\n");
    const capacity = rows - @intFromBool(rows > 1);
    const first = selected -| (capacity - 1);
    var buffer: [80]u8 = undefined;
    for (first..@min(first + capacity, config.activities().len)) |index| {
        if (index != first) try output("\r\n");
        try output(try std.fmt.bufPrint(&buffer, "{s}{d}: ", .{ if (index == selected) "> " else "  ", index + 1 }));
        try activityName(config.activities()[index].name);
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

fn activityRow(screen: *Screen, key: ?u8, activity: timer.Activity, active: bool, seconds: u128) !void {
    if (!try screen.line()) return;
    var buffer: [80]u8 = undefined;
    try output(&.{ if (active) '>' else ' ', ' ', key orelse '-', ' ', ' ' });
    try output(try duration(&buffer, seconds));
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

fn draw(config: Config, live: timer.Timer, seconds: u64, status: []const u8, totals: []const timer.totals.Total) !void {
    var size: c.struct_winsize = std.mem.zeroes(c.struct_winsize);
    if (c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &size) != 0) return error.TerminalSizeFailed;
    try output("\x1b[H\x1b[2J\x1b[?7l");
    defer output("\x1b[?7h") catch {};
    const rows: usize = @max(size.ws_row, 1);
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
        if (try screen.line()) try output("Key  Today     Activity (> running)");
    }
    for (config.activities(), 0..) |activity, index| {
        var ns: u128 = 0;
        for (totals) |total| {
            if (std.mem.eql(u8, activity.id, total.activity.id)) {
                ns = total.duration_ns;
                break;
            }
        }
        const active = if (live.running) |running| std.mem.eql(u8, running.activity.id, activity.id) else false;
        try activityRow(&screen, config.numericKey(index), activity, active, ns / std.time.ns_per_s);
    }
    for (totals) |total| {
        for (config.activities()) |activity| {
            if (std.mem.eql(u8, activity.id, total.activity.id)) break;
        } else {
            try activityRow(&screen, null, total.activity, false, total.duration_ns / std.time.ns_per_s);
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
    try output(if (size.ws_col >= 50) "1-9: toggle | a: activities | e: export | q: quit" else if (size.ws_col >= 18) "a menu e csv q quit" else "a e q");
}
