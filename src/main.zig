const std = @import("std");
const builtin = @import("builtin");
const c = @import("terminal_c");

var stopping = std.atomic.Value(bool).init(false);
var resized = std.atomic.Value(bool).init(false);

fn onSignal(sig: c_int) callconv(.c) void {
    if (sig == c.SIGWINCH) resized.store(true, .monotonic) else stopping.store(true, .monotonic);
}

pub fn main() void {
    run() catch |err| {
        std.debug.print("bad_timer: {s}\n", .{@errorName(err)});
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

fn run() !void {
    if (builtin.os.tag != .macos) return error.RequiresMacOS;
    if (c.isatty(c.STDIN_FILENO) != 1 or c.isatty(c.STDOUT_FILENO) != 1)
        return error.RequiresInteractiveTTY;
    const term = c.getenv("TERM") orelse return error.RequiresGhostty;
    if (!std.mem.eql(u8, std.mem.span(term), "xterm-ghostty")) return error.RequiresGhostty;

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
            try draw(last_key);
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
        last_key = key;
        dirty = true;
    }
}

fn draw(key: ?u8) !void {
    var size: c.struct_winsize = std.mem.zeroes(c.struct_winsize);
    if (c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &size) != 0) return error.TerminalSizeFailed;
    var buffer: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "\x1b[H\x1b[2Jbad-timer foundation\r\n{d} columns x {d} rows\r\nLast key byte: {d}\r\nq: quit | Ctrl-C: quit\r\nNo timer or storage yet.\r\n", .{ size.ws_col, size.ws_row, key orelse 0 });
    try output(text);
}
