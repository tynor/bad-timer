"""macOS PTY checks; run after zig build: python3 tests/terminal_smoke.py."""
import errno
import json
import resource
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import termios
import time
import tempfile
from pathlib import Path

EXE = "./zig-out/bin/bad_timer"
HOME = tempfile.TemporaryDirectory(prefix="bad-timer-test-")
ENV = dict(os.environ, TERM="xterm-ghostty", HOME=HOME.name)
CONFIG = Path(HOME.name) / "Library/Application Support/bad-timer/config.json"
CONFIG.parent.mkdir(parents=True)
VALID_CONFIG = b'{"activities":[{"id":"work","name":"Work"}]}'
CONFIG.write_bytes(VALID_CONFIG)


def receive(fd, needle):
    data = b""
    deadline = time.monotonic() + 5
    while needle not in data and time.monotonic() < deadline:
        if select.select([fd], [], [], 0.1)[0]:
            try:
                data += os.read(fd, 8192)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                break
    assert needle in data, (needle, data)
    return data


def launch(output=None, args=(), env=ENV, file_size_limit=None):
    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))

    def controlling_terminal():
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        if file_size_limit is not None:
            signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
            resource.setrlimit(resource.RLIMIT_FSIZE, (file_size_limit, file_size_limit))

    process = subprocess.Popen(
        [EXE, *args], stdin=slave, stdout=slave if output is None else output,
        stderr=subprocess.PIPE, env=env, preexec_fn=controlling_terminal,
    )
    return process, master, slave, original


# Overrides work without HOME and take precedence over the default config.
override = Path(HOME.name) / "custom config.json"
override.write_bytes(VALID_CONFIG)
without_home = dict(ENV)
without_home.pop("HOME", None)
for path in (str(override), os.path.relpath(override)):
    process, master, slave, original = launch(args=("--config", path, "--history", str(override) + ".jsonl"), env=without_home)
    try:
        receive(master, b"History loaded; no timer controls yet.")
        os.write(master, b"q")
        receive(master, b"\x1b[?25h\x1b[?1049l")
        assert process.wait(timeout=5) == 0, process.stderr.read()
        assert termios.tcgetattr(master) == original
    finally:
        os.close(master)
        os.close(slave)
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)

for args, expected in (
    (("--config",), b"usage:"),
    (("--config", ""), b"usage:"),
    (("--unknown",), b"usage:"),
    (("--history",), b"usage:"),
    (("--history", ""), b"usage:"),
    (("--history", "a", "--history", "b"), b"usage:"),
    (("--config", str(override), "--config", str(override)), b"usage:"),
    (("--config", "--config"), b"usage:"),
    (("--config", str(override) + ".missing"), b"FileNotFound"),
):
    process, master, slave, original = launch(args=args)
    try:
        assert process.wait(timeout=5) == 1
        diagnostic = process.stderr.read()
        assert expected in diagnostic, diagnostic
        assert termios.tcgetattr(master) == original
    finally:
        os.close(master)
        os.close(slave)
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
assert override.read_bytes() == VALID_CONFIG

# Config failures must happen before raw mode or alternate-screen entry.
for contents, mode, expected in (
    (None, 0o600, b"FileNotFound"),
    (b"{", 0o600, b"cannot load config"),
    (b'{"activities":[]}', 0o600, b"NoActivities"),
    (VALID_CONFIG, 0o000, b"AccessDenied"),
    (b" " * (1024 * 1024 + 1), 0o600, b"StreamTooLong"),
):
    CONFIG.unlink(missing_ok=True)
    if contents is not None:
        CONFIG.write_bytes(contents)
        CONFIG.chmod(mode)
    process, master, slave, original = launch()
    try:
        assert process.wait(timeout=5) == 1
        diagnostic = process.stderr.read()
        assert expected in diagnostic, diagnostic
        assert str(CONFIG).encode() in diagnostic, diagnostic
        assert termios.tcgetattr(master) == original
        if select.select([master], [], [], 0.1)[0]:
            try:
                assert os.read(master, 8192) == b"", "output before config validation"
            except OSError as error:
                assert error.errno == errno.EIO
        if contents is None:
            assert not CONFIG.exists()
        else:
            CONFIG.chmod(0o600)
            assert CONFIG.read_bytes() == contents, "config was modified"
    finally:
        if CONFIG.exists():
            CONFIG.chmod(0o600)
        os.close(master)
        os.close(slave)
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
CONFIG.write_bytes(VALID_CONFIG)

# History failures preserve bytes and terminal state; locks exclude other processes.
history = Path(HOME.name) / "custom history.jsonl"
for contents, mode, expected in (
    (b"{", 0o600, b"IncompleteTrailingRecord"),
    (b"{}\n", 0o600, b"cannot load history"),
    (b"", 0o000, b"AccessDenied"),
):
    history.write_bytes(contents)
    history.chmod(mode)
    process, master, slave, original = launch(args=("--history", str(history)))
    try:
        assert process.wait(timeout=5) == 1
        diagnostic = process.stderr.read()
        assert expected in diagnostic and str(history).encode() in diagnostic, diagnostic
        assert termios.tcgetattr(master) == original
        history.chmod(0o600)
        assert history.read_bytes() == contents
    finally:
        history.chmod(0o600)
        os.close(master)
        os.close(slave)
history.unlink()
for iteration in range(2):
    process, master, slave, original = launch(args=("--history", str(history)))
    try:
        receive(master, b"History loaded;")
        assert history.read_bytes() == b""
        assert history.stat().st_mode & 0o777 == 0o600
        second, m2, s2, original2 = launch(args=("--history", str(history)))
        try:
            assert second.wait(timeout=5) == 1
            assert b"HistoryLocked" in second.stderr.read()
            assert termios.tcgetattr(m2) == original2
        finally:
            os.close(m2)
            os.close(s2)
        os.write(master, b"q")
        receive(master, b"\x1b[?25h\x1b[?1049l")
        assert process.wait(timeout=5) == 0, process.stderr.read()
    finally:
        os.close(master)
        os.close(slave)
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)

# Recovery is explicit, append-only, and independent of the current activity config.
start = json.dumps({"version": 1, "change": {"start": {
    "session_id": 7, "activity": {"id": "removed", "name": "Old name"},
    "start_utc_ns": 100,
}}}).encode() + b"\n"
for action in (b"q", b"\x03", signal.SIGTERM, b"d", "write_failure"):
    history.write_bytes(start)
    process, master, slave, original = launch(
        args=("--history", str(history)),
        file_size_limit=len(start) if action == "write_failure" else None,
    )
    try:
        receive(master, b"Supplying an end time is not supported yet.")
        os.write(master, b"1a\r")  # Unrelated keys cannot resolve recovery.
        receive(master, b"Unfinished session 7")
        assert history.read_bytes() == start
        if action == "write_failure":
            os.write(master, b"d")
            receive(master, b"\x1b[?25h\x1b[?1049l")
            assert process.wait(timeout=5) == 1
            diagnostic = process.stderr.read()
            assert b"discard failed" in diagnostic and b"disk may contain" in diagnostic
            assert history.read_bytes() == start
        else:
            if isinstance(action, bytes):
                os.write(master, action)
            else:
                os.kill(process.pid, action)
            if action == b"d":
                receive(master, b"History loaded; no timer controls yet.")
                saved = history.read_bytes()
                assert saved.startswith(start)
                assert json.loads(saved[len(start):]) == {
                    "version": 1, "change": {"discard": {"session_id": 7}}
                }
                os.write(master, b"q")
            receive(master, b"\x1b[?25h\x1b[?1049l")
            assert process.wait(timeout=5) == 0, process.stderr.read()
            if action != b"d":
                assert history.read_bytes() == start
        assert termios.tcgetattr(master) == original
    finally:
        os.close(master)
        os.close(slave)
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)

    # Reopening must reflect exactly the durable recovery decision.
    process, master, slave, original = launch(args=("--history", str(history)))
    try:
        receive(master, b"History loaded;" if action == b"d" else b"Unfinished session 7")
        os.write(master, b"q")
        receive(master, b"\x1b[?25h\x1b[?1049l")
        assert process.wait(timeout=5) == 0, process.stderr.read()
        assert termios.tcgetattr(master) == original
    finally:
        os.close(master)
        os.close(slave)
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)

for exit_key in (b"q", b"\x03", signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT):
    print("checking", repr(exit_key), flush=True)
    process, master, slave, original = launch()
    try:
        receive(master, b"History loaded; no timer controls yet.")
        assert not select.select([master], [], [], 1.2)[0], "idle redraw"
        os.write(master, b"x")
        receive(master, b"Last key byte: 120")
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        os.kill(process.pid, signal.SIGWINCH)
        receive(master, b"100 columns x 30 rows")
        if isinstance(exit_key, bytes):
            os.write(master, exit_key)
        else:
            os.kill(process.pid, exit_key)
        receive(master, b"\x1b[?25h\x1b[?1049l")
        assert process.wait(timeout=5) == 0, process.stderr.read()
        assert termios.tcgetattr(master) == original, "terminal settings changed"
    finally:
        os.close(master)
        os.close(slave)
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)

# A disconnected output terminal must unwind raw mode on the input terminal.
out_master, out_slave = pty.openpty()
process, master, slave, original = launch(out_slave)
try:
    receive(out_master, b"History loaded; no timer controls yet.")
    os.close(out_master)
    os.write(master, b"x")
    assert process.wait(timeout=5) == 1
    assert termios.tcgetattr(master) == original
    assert b"Terminal" in process.stderr.read()
finally:
    if process.poll() is None:
        process.kill()
        process.wait(timeout=5)
    for fd in (master, slave, out_slave):
        os.close(fd)

result = subprocess.run([EXE], input=b"", capture_output=True, env=ENV, timeout=5)
assert result.returncode == 1 and b"RequiresInteractiveTTY" in result.stderr
master, slave = pty.openpty()
try:
    original = termios.tcgetattr(slave)
    result = subprocess.run([EXE], stdin=slave, stdout=slave, stderr=subprocess.PIPE,
                            env=dict(ENV, TERM="xterm-256color"), timeout=5)
    assert result.returncode == 1 and b"RequiresGhostty" in result.stderr
    assert termios.tcgetattr(slave) == original
finally:
    os.close(master)
    os.close(slave)
HOME.cleanup()
print("terminal smoke checks passed")
