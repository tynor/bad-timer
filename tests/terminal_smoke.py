"""macOS PTY checks; run after zig build: python3 tests/terminal_smoke.py."""
import csv
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
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

EXE = str(Path("./zig-out/bin/bad_timer").resolve())
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


def launch(output=None, args=(), env=ENV, file_size_limit=None, cwd=None):
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
        stderr=subprocess.PIPE, env=env, preexec_fn=controlling_terminal, cwd=cwd,
    )
    return process, master, slave, original


# Configured-zone totals include removed activities, exclude yesterday, and survive restart.
with tempfile.TemporaryDirectory(prefix="bad-timer-totals-") as directory:
    history = Path(directory) / "history.jsonl"
    config = Path(directory) / "config.json"
    zone = ZoneInfo("Pacific/Kiritimati")
    midnight = datetime.now(zone).replace(hour=0, minute=0, second=0, microsecond=0)
    config.write_text(json.dumps({"time_zone": zone.key, "activities": [{"id": "work", "name": "Work"}]}))
    events = []
    for session_id, date, name in ((1, midnight, "Removed"), (2, midnight - timedelta(days=1), "Yesterday")):
        activity = {"id": name.lower(), "name": name}
        start_ns = int(date.timestamp()) * 1_000_000_000
        events.extend([
            {"version": 1, "change": {"start": {"session_id": session_id, "activity": activity, "start_utc_ns": start_ns}}},
            {"version": 1, "change": {"stop": {"session_id": session_id, "activity": activity, "end_utc_ns": start_ns, "duration_ns": 7_000_000_000}}},
        ])
    history.write_text("".join(json.dumps(event) + "\n" for event in events))
    for restart in (False, True):
        process, master, slave, original = launch(args=("--config", str(config), "--history", str(history)))
        try:
            screen = receive(master, b"1: Work")
            assert b"Today's totals (Pacific/Kiritimati)" in screen
            assert b"7 seconds: Removed" in screen and b"Yesterday" not in screen
            if not restart:
                before = history.read_bytes()
                os.write(master, b"1")
                receive(master, b"1 seconds: Work")
                os.write(master, b"1")
                receive(master, b"Stopped")
                assert history.read_bytes().startswith(before)
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 3, 20, 0, 0))
                process.send_signal(signal.SIGWINCH)
                receive(master, b"More rows: enlarge terminal")
                assert process.poll() is None
            else:
                assert b"seconds: Work" in screen
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

# Export skips existing destinations, excludes live time, and never changes history.
with tempfile.TemporaryDirectory(prefix="bad-timer-export-") as directory:
    reports = Path(directory)
    history = reports / "history.jsonl"
    existing = reports / "bad-timer-1.csv"
    existing.write_bytes(b"keep me")
    process, master, slave, original = launch(cwd=directory, args=("--history", str(history)))
    try:
        receive(master, b"Timer controls ready.")
        os.write(master, b"e")
        receive(master, b"Exported completed sessions to ./bad-timer-2.csv")
        assert len(list(csv.reader((reports / "bad-timer-2.csv").open()))) == 1
        assert history.read_bytes() == b""
        os.write(master, b"1")
        receive(master, b"Active: Work")
        before = history.read_bytes()
        os.write(master, b"e")
        receive(master, b"Exported completed sessions to ./bad-timer-3.csv")
        assert history.read_bytes() == before
        assert len(list(csv.reader((reports / "bad-timer-3.csv").open()))) == 1
        os.write(master, b"1")
        receive(master, b"Stopped")
        before = history.read_bytes()
        os.write(master, b"e")
        receive(master, b"Exported completed sessions to ./bad-timer-4.csv")
        rows = list(csv.reader((reports / "bad-timer-4.csv").open()))
        assert len(rows) == 2 and rows[1][:2] == ["work", "Work"], rows
        assert history.read_bytes() == before
        assert existing.read_bytes() == b"keep me"
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

# A failed report write is nonfatal, preserves history, and removes temporary files.
with tempfile.TemporaryDirectory(prefix="bad-timer-export-failure-") as directory:
    history = Path(directory) / "history.jsonl"
    process, master, slave, original = launch(cwd=directory, args=("--history", str(history)), file_size_limit=0)
    try:
        receive(master, b"Timer controls ready.")
        os.write(master, b"e")
        receive(master, b"history unchanged.")
        assert process.poll() is None
        assert history.read_bytes() == b""
        assert list(Path(directory).iterdir()) == [history]
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

# Overrides work without HOME and take precedence over the default config.
override = Path(HOME.name) / "custom config.json"
override.write_bytes(VALID_CONFIG)
without_home = dict(ENV)
without_home.pop("HOME", None)
for path in (str(override), os.path.relpath(override)):
    process, master, slave, original = launch(args=("--config", path, "--history", str(override) + ".jsonl"), env=without_home)
    try:
        receive(master, b"Timer controls ready.")
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
        receive(master, b"Timer controls ready.")
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
        receive(master, b"q / Ctrl-C: exit without changing history")
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
                receive(master, b"Timer controls ready.")
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
        receive(master, b"Timer controls ready." if action == b"d" else b"Unfinished session 7")
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

# Supplied end times require validation and a separate durable confirmation.
for action, duration_input in [(a, d) for d in (False, True) for a in ("save", "cancel", "quit", "interrupt", "failure")]:
    history.write_bytes(start)
    process, master, slave, original = launch(
        args=("--history", str(history)),
        file_size_limit=len(start) if action == "failure" else None,
    )
    try:
        receive(master, b"t: supply UTC end time")
        os.write(master, b"u-1s\r" if duration_input else b"t1969-12-31T23:59:59Z\r")
        receive(master, b"Invalid duration" if duration_input else b"Invalid end time")
        assert history.read_bytes() == start
        if duration_input:
            os.write(master, b"\x1bu" + b"0s" * 128 + b"1h\r")
            receive(master, b"Esc: restart.")
            assert history.read_bytes() == start
        os.write(master, "\x1bu1µs2.5ms\r".encode() if duration_input else b"\x1bt1970-01-01T00:00:01Z\r")
        review = receive(master, b"y: confirm and save")
        if duration_input:
            assert b"Derived end UTC (Unix nanoseconds): 2501100" in review
        assert history.read_bytes() == start
        if action in ("save", "failure"):
            os.write(master, b"y")
            if action == "save":
                receive(master, b"Timer controls ready.")
                saved = history.read_bytes()
                assert saved.startswith(start)
                stop = json.loads(saved[len(start):])["change"]["stop"]
                assert stop == {"session_id": 7, "activity": {"id": "removed", "name": "Old name"},
                                "end_utc_ns": 2501100 if duration_input else 1000000000,
                                "duration_ns": 2501000 if duration_input else 999999900}
                os.write(master, b"q")
        elif action == "cancel":
            os.write(master, b"\x1b")
            receive(master, b"t: supply UTC end time")
            os.write(master, b"q")
        else:
            os.write(master, b"q" if action == "quit" else b"\x03")
        receive(master, b"\x1b[?25h\x1b[?1049l")
        assert process.wait(timeout=5) == (1 if action == "failure" else 0)
        if action == "failure":
            diagnostic = process.stderr.read()
            assert b"recovery failed" in diagnostic and b"disk may contain" in diagnostic
        if action != "save":
            assert history.read_bytes() == start
        assert termios.tcgetattr(master) == original
    finally:
        os.close(master)
        os.close(slave)
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
    process, master, slave, original = launch(args=("--history", str(history)))
    try:
        receive(master, b"Timer controls ready." if action == "save" else b"Unfinished session 7")
        os.write(master, b"q")
        receive(master, b"\x1b[?25h\x1b[?1049l")
        assert process.wait(timeout=5) == 0
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
        receive(master, b"\x1b[?7h")
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

# Numeric controls persist atomic switches, same-key stops, and clean exits.
controls = Path(HOME.name) / "controls.json"
controls.write_text(json.dumps({"activities": [
    {"id": "work", "name": "Work"}, {"id": "rest", "name": "Rest"}]}))
tracked = Path(HOME.name) / "controls.jsonl"
for exit_key in (b"q", b"\x03", signal.SIGTERM):
    tracked.write_bytes(b"")
    process, master, slave, original = launch(args=("--config", str(controls), "--history", str(tracked)))
    try:
        receive(master, b"2: Rest")
        for key, marker in ((b"1", b"Active: Work"), (b"2", b"Active: Rest"),
                            (b"2", b"Stopped"), (b"1", b"Active: Work")):
            os.write(master, key)
            receive(master, marker)
        receive(master, b"Elapsed: 1 seconds")
        if isinstance(exit_key, bytes):
            os.write(master, exit_key)
        else:
            os.kill(process.pid, exit_key)
        receive(master, b"\x1b[?25h\x1b[?1049l")
        assert process.wait(timeout=5) == 0, process.stderr.read()
        assert termios.tcgetattr(master) == original
        changes = [json.loads(line)["change"] for line in tracked.read_bytes().splitlines()]
        assert [next(iter(c)) for c in changes] == ["start", "switch_activity", "stop", "start", "stop"]
        switch = changes[1]["switch_activity"]
        assert switch["stop"]["end_utc_ns"] == switch["start"]["start_utc_ns"]
        assert changes[-1]["stop"]["duration_ns"] >= 1_000_000_000
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        os.close(master)
        os.close(slave)
    process, master, slave, original = launch(args=("--history", str(tracked)))
    try:
        receive(master, b"Stopped")
        saved = tracked.read_bytes()
        os.write(master, b"q")
        receive(master, b"\x1b[?25h\x1b[?1049l")
        assert process.wait(timeout=5) == 0
        assert tracked.read_bytes() == saved
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        os.close(master)
        os.close(slave)

# Menu selection reaches beyond nine, scrolls after resize, and uses durable toggles.
menu_config = Path(HOME.name) / "menu.json"
menu_config.write_text(json.dumps({"activities": [
    {"id": str(i), "name": f"Activity {i}"} for i in range(1, 13)]}))
menu_history = Path(HOME.name) / "menu.jsonl"
process, master, slave, original = launch(args=("--config", str(menu_config), "--history", str(menu_history)))
try:
    receive(master, b"9: Activity 9")
    os.write(master, b"1")
    receive(master, b"Active: Activity 1")
    saved = menu_history.read_bytes()
    os.write(master, b"a")
    receive(master, b"> 1: Activity 1")
    # Fragmented CSI and application-cursor arrows are both accepted.
    os.write(master, b"\x1b")
    time.sleep(0.01)
    os.write(master, b"[B")
    receive(master, b"> 2: Activity 2")
    os.write(master, b"\x1bOA")
    receive(master, b"> 1: Activity 1")
    os.write(master, b"\x1b")
    receive(master, b"Active: Activity 1")
    assert menu_history.read_bytes() == saved, "cancel changed timing"
    os.write(master, b"a")
    receive(master, b"> 1: Activity 1")
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 4, 40, 0, 0))
    os.kill(process.pid, signal.SIGWINCH)
    receive(master, b"> 1: Activity 1")
    for i in range(2, 11):
        os.write(master, b"\x1b[B")
        screen = receive(master, f"> {i}: Activity {i}".encode())
    assert b"  1: Activity 1\r\n" not in screen, "menu did not scroll"
    os.write(master, b"\r")
    receive(master, b"More rows: enlarge terminal")
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    os.kill(process.pid, signal.SIGWINCH)
    receive(master, b"Active: Activity 10")
    os.write(master, b"a")
    receive(master, b"> 1: Activity 1")
    for i in range(2, 11):
        os.write(master, b"\x1b[B")
        receive(master, f"> {i}: Activity {i}".encode())
    os.write(master, b"\r")
    receive(master, b"Stopped")
    os.write(master, b"a")
    receive(master, b"> 1: Activity 1")
    os.write(master, b"\r")
    receive(master, b"Active: Activity 1")
    os.write(master, b"q")
    receive(master, b"\x1b[?25h\x1b[?1049l")
    assert process.wait(timeout=5) == 0, process.stderr.read()
    assert termios.tcgetattr(master) == original
    changes = [json.loads(line)["change"] for line in menu_history.read_bytes().splitlines()]
    assert [next(iter(c)) for c in changes] == ["start", "switch_activity", "stop", "start", "stop"]
    switch = changes[1]["switch_activity"]
    assert switch["start"]["activity"]["id"] == "10"
    assert switch["stop"]["end_utc_ns"] == switch["start"]["start_utc_ns"]
finally:
    if process.poll() is None:
        process.kill()
        process.wait(timeout=5)
    os.close(master)
    os.close(slave)

# Failed timer appends exit with uncertainty and never acknowledge a start.
tracked.write_bytes(b"")
process, master, slave, original = launch(args=("--history", str(tracked)), file_size_limit=0)
try:
    receive(master, b"Timer controls ready.")
    os.write(master, b"1")
    receive(master, b"\x1b[?25h\x1b[?1049l")
    assert process.wait(timeout=5) == 1
    assert b"disk may contain" in process.stderr.read()
    assert tracked.read_bytes() == b""
    assert termios.tcgetattr(master) == original
finally:
    if process.poll() is None:
        process.kill()
        process.wait(timeout=5)
    os.close(master)
    os.close(slave)

# A disconnected output terminal must unwind raw mode on the input terminal.
out_master, out_slave = pty.openpty()
fcntl.ioctl(out_slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
process, master, slave, original = launch(out_slave)
try:
    receive(out_master, b"\x1b[?7h")
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
