const std = @import("std");
const builtin = @import("builtin");
const c = @import("terminal_c");
const Config = @import("bad_timer").config.Config;

var stopping = std.atomic.Value(bool).init(false);
var resized = std.atomic.Value(bool).init(false);

fn onSignal(sig: c_int) callconv(.c) void {
    if (sig == c.SIGWINCH) resized.store(true, .monotonic) else stopping.store(true, .monotonic);
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("bad_timer: {s}\n", .{@errorName(err)});
        if (err == error.InvalidArguments)
            std.debug.print("usage: bad_timer [--config PATH] [--history PATH]\n", .{});
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

fn run(init: std.process.Init) !void {
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

    var last_key: ?u8 = null;
    var dirty = true;
    while (!stopping.load(.monotonic)) {
        if (resized.swap(false, .monotonic)) dirty = true;
        if (dirty) {
            if (store.history.unfinished) |session| {
                var buffer: [512]u8 = undefined;
                try output(try std.fmt.bufPrint(&buffer, "\x1b[H\x1b[2JUnfinished session {d}\r\nNo time will be counted automatically.\r\nd: discard unfinished session (adds no time)\r\nq / Ctrl-C: exit without changing history\r\nSupplying an end time is not supported yet.\r\n", .{session.session_id}));
            } else {
                try draw(last_key);
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
        if (store.history.unfinished) |session| {
            if (key == 'd') {
                store.append(init.io, .{ .version = 1, .change = .{ .discard = .{ .session_id = session.session_id } } }) catch |err| {
                    std.debug.print("bad_timer: discard failed at {s}: {s}; disk may contain part or all of the event; preserve the history file and restart to inspect it; do not retry in this process\n", .{ locations.history, @errorName(err) });
                    return error.HistoryDiscardFailed;
                };
            }
            dirty = true;
            continue;
        }
        last_key = key;
        dirty = true;
    }
}

fn draw(key: ?u8) !void {
    var size: c.struct_winsize = std.mem.zeroes(c.struct_winsize);
    if (c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &size) != 0) return error.TerminalSizeFailed;
    var buffer: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "\x1b[H\x1b[2Jbad-timer foundation\r\n{d} columns x {d} rows\r\nLast key byte: {d}\r\nq: quit | Ctrl-C: quit\r\nHistory loaded; no timer controls yet.\r\n", .{ size.ws_col, size.ws_row, key orelse 0 });
    try output(text);
}
