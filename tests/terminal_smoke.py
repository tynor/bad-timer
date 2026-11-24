"""macOS PTY checks; run after zig build: python3 tests/terminal_smoke.py."""
import csv
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
import errno
import json
import resource
import re
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


class FrameProtocol:
    def __init__(self):
        self.pending = b""
        self.active = False
        self.recent = []

    def feed(self, chunk):
        self.pending += chunk
        end = 0
        for match in re.finditer(rb"\x1b\[[0-?]*[ -/]*[@-~]", self.pending):
            code = match.group()
            if code == b"\x1b[?2026h":
                assert not self.active, "nested synchronized frame"
                self.active = True
            elif code == b"\x1b[?2026l":
                self.active = False  # Cleanup may defensively reset an inactive mode.
            elif code == b"\x1b[2J":
                assert self.active, "screen clear outside synchronized frame"
            elif code in (b"\x1b[?7h", b"\x1b[?1049l"):
                assert not self.active, "frame not ended before wrap restoration/exit"
                if code == b"\x1b[?1049l":
                    assert self.recent == [b"\x1b[?2026l", b"\x1b[?7h", b"\x1b[?25h"], "missing defensive exit reset"
            self.recent = (self.recent + [code])[-3:]
            end = match.end()
        self.pending = self.pending[end:]


# Check split markers and prove the protocol assertions catch missing frame ends.
protocol = FrameProtocol()
for chunk in (b"\x1b[?202", b"6h\x1b[2Jframe\x1b[?2026", b"l\x1b[?7h"):
    protocol.feed(chunk)
assert not protocol.active
protocol.feed(b"\x1b[?2026l\x1b[?7h\x1b[?25h\x1b[?1049l")
for invalid in (b"\x1b[2J", b"\x1b[?2026h\x1b[?7h", b"\x1b[?2026h\x1b[?2026h", b"\x1b[?1049l"):
    try:
        FrameProtocol().feed(invalid)
    except AssertionError:
        pass
    else:
        raise AssertionError("protocol check accepted an invalid frame")


PROTOCOLS = {}


def receive(fd, needle):
    data = b""
    deadline = time.monotonic() + 5
    while needle not in data and time.monotonic() < deadline:
        if select.select([fd], [], [], 0.1)[0]:
            try:
                chunk = os.read(fd, 8192)
                PROTOCOLS.setdefault(fd, FrameProtocol()).feed(chunk)
                data += chunk
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                break
    assert needle in data, (needle, data)
    return data


def receive_frame(fd, needle):
    data = receive(fd, needle)
    if b"\x1b[?7h" not in data[data.index(needle):]:
        data += receive(fd, b"\x1b[?7h")
    return data


def launch(output=None, args=(), env=ENV, file_size_limit=None, cwd=None):
    master, slave = pty.openpty()
    PROTOCOLS[master] = FrameProtocol()
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


# Explicit tail recovery bypasses HOME/config/TERM and never enters raw/alternate mode.
with tempfile.TemporaryDirectory(prefix="bad-timer-recovery-cli-") as directory:
    source = Path(directory) / "source.jsonl"
    destination = Path(directory) / "destination.jsonl"
    activity = {"id": "removed", "name": "Historical"}
    prefix = (json.dumps({"version": 1, "change": {"start": {
        "session_id": 7, "activity": activity, "start_utc_ns": 100,
    }}}) + "\n").encode()
    stop = (json.dumps({"version": 1, "change": {"stop": {
        "session_id": 7, "activity": activity, "end_utc_ns": 200, "duration_ns": 100,
    }}}) + "\n").encode()
    recovery_env = dict(ENV, TERM="dumb")
    recovery_env.pop("HOME", None)
    for case in ("cancel", "overlong", "eof", "interrupt", "save", "completed", "corrupt", "transition", "existing", "complete", "write_failure"):
        print("recovery CLI", case, flush=True)
        content = prefix + (stop if case == "completed" else b"") + b"partial"
        if case == "corrupt":
            content = b"{bad}\npartial"
        elif case == "transition":
            content = stop + b"partial"
        elif case == "complete":
            content = prefix
        source.write_bytes(content)
        destination.unlink(missing_ok=True)
        if case == "existing":
            destination.write_bytes(b"keep")
        before = source.stat().st_mtime_ns
        process, master, slave, original = launch(
            args=("--recover-history", str(source), str(destination)), env=recovery_env,
            file_size_limit=0 if case == "write_failure" else None,
        )
        try:
            screen = receive(master, b"anything else cancels: ")
            assert b"not lossless repair" in screen and b"\x1b[" not in screen
            assert not destination.exists() or case == "existing"
            assert termios.tcgetattr(master) == original
            if case == "interrupt":
                os.write(master, b"\x03")
                receive(master, b"^C")
                assert process.wait(timeout=5) == -signal.SIGINT
            else:
                os.write(master, {"cancel": b"no\n", "overlong": b"yesplease\n", "eof": b"\x04"}.get(case, b"yes\n"))
                if case in ("cancel", "overlong", "eof"):
                    receive(master, b"Cancelled; no files changed.")
                    assert process.wait(timeout=5) == 0
                elif case in ("save", "completed"):
                    result = receive(master, b"Neither file was activated automatically.")
                    expected = prefix + (stop if case == "completed" else b"")
                    assert destination.read_bytes() == expected
                    assert f"retained {len(expected)} bytes; omitted 7 uncertain bytes".encode() in result
                    assert (b"Unfinished session 7" if case == "save" else b"No unfinished session") in result
                    assert process.wait(timeout=5) == 0
                else:
                    # Drain canonical echo before waiting: macOS may drain PTY output on exit.
                    receive(master, b"yes\r\n")
                    stderr = process.stderr.read()
                    assert process.wait(timeout=5) == 1, stderr
                    assert b"recovery failed:" in stderr
            assert source.read_bytes() == content and source.stat().st_mtime_ns == before
            assert termios.tcgetattr(master) == original
            if case == "existing":
                assert destination.read_bytes() == b"keep"
            elif case not in ("save", "completed"):
                assert not destination.exists()
            assert set(Path(directory).iterdir()) == {source} | ({destination} if destination.exists() else set())
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            os.close(master)
            os.close(slave)
    for args in (("--recover-history",), ("--recover-history", str(source)),
                 ("--recover-history", "", str(destination)),
                 ("--recover-history", str(source), str(destination), "extra"),
                 ("--recover-history", "--config", str(destination))):
        result = subprocess.run([EXE, *args], input=b"yes\n", capture_output=True, env=recovery_env, timeout=5)
        assert result.returncode == 1 and b"usage:" in result.stderr
    result = subprocess.run([EXE, "--recover-history", str(source), str(destination)], input=b"yes\n", capture_output=True, env=recovery_env, timeout=5)
    assert result.returncode == 1 and b"RequiresInteractiveTTY" in result.stderr
    assert not destination.exists()

# Summary screens use calendar windows, remain read-only, scroll, and retain live time.
with tempfile.TemporaryDirectory(prefix="bad-timer-summaries-") as directory:
    root = Path(directory)
    config = root / "config.json"
    history = root / "history.jsonl"
    zone = ZoneInfo("Pacific/Kiritimati")
    today = datetime.now(zone).replace(hour=0, minute=0, second=0, microsecond=0)
    monday = today - timedelta(days=today.weekday())
    config.write_text(json.dumps({"time_zone": zone.key, "activities": [{"id": "work", "name": "Work"}]}))
    fixtures = [(today, "Removed", 7), (today - timedelta(days=6), "Six days ago", 6),
                (monday - timedelta(weeks=3), "Three weeks ago", 13),
                (monday - timedelta(weeks=4), "Outside window", 99)]
    events = []
    for session_id, (date, name, seconds) in enumerate(fixtures, 1):
        activity = {"id": name, "name": name}
        ns = int(date.timestamp()) * 1_000_000_000
        events.extend([
            {"version": 1, "change": {"start": {"session_id": session_id, "activity": activity, "start_utc_ns": ns}}},
            {"version": 1, "change": {"stop": {"session_id": session_id, "activity": activity, "end_utc_ns": ns, "duration_ns": seconds * 1_000_000_000}}},
        ])
    history.write_text("".join(json.dumps(event) + "\n" for event in events))
    before = history.read_bytes()
    process, master, slave, original = launch(args=("--config", str(config), "--history", str(history)), cwd=directory)
    try:
        receive(master, b"\x1b[?7h")
        migrated = history.read_bytes()
        assert migrated.startswith(before)
        assert json.loads(migrated[len(before):]) == {"version": 2, "change": {"legacy_timezone": zone.key}}
        before = migrated
        os.write(master, b"d")
        screen = receive_frame(master, b"Daily summaries")
        assert b"Pacific/Kiritimati" in screen and b"00:00:07  Removed" in screen
        assert b"Three weeks ago" not in screen and b"Outside window" not in screen
        for days in range(7):
            assert (today - timedelta(days=days)).strftime("%Y-%m-%d").encode() in screen, screen
        assert b"No time recorded" in screen and b"(current)" in screen
        assert not select.select([master], [], [], 1.2)[0], "idle summary redraw"
        for key in (b"1", b"a", b"e"):
            os.write(master, key)
            receive_frame(master, b"Daily summaries")
        assert history.read_bytes() == before and not list(root.glob("*.csv"))
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 4, 40, 0, 0))
        process.send_signal(signal.SIGWINCH)
        receive_frame(master, b"Daily summaries")
        seen = b""
        for _ in range(20):
            os.write(master, b"\x1b[B")
            seen += receive_frame(master, b"Daily summaries")
        assert b"Six days ago" in seen
        assert b"\x1b[4;1HUp/Down: scroll" in seen and b"\x1b[5;1H" not in seen
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 1, 20, 0, 0))
        process.send_signal(signal.SIGWINCH)
        tiny = receive(master, b"\x1b[?7h")
        assert b"\x1b[2;1H" not in tiny
        os.write(master, b"\x1b[A")
        receive(master, b"\x1b[?7h")
        os.write(master, b"\x1b")
        receive_frame(master, b"d/w sums a menu q")
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        process.send_signal(signal.SIGWINCH)
        receive_frame(master, b"Stopped")
        os.write(master, b"w")
        screen = receive_frame(master, b"Weekly summaries")
        for weeks in range(4):
            start_date = monday - timedelta(weeks=weeks)
            end_date = start_date + timedelta(days=6)
            expected = sum(seconds for date, _, seconds in fixtures if start_date <= date <= end_date)
            label = f"{start_date:%Y-%m-%d}..{end_date:%Y-%m-%d} | 00:00:{expected:02d}"
            assert label.encode() in screen, (label, screen)
        assert b"Three weeks ago" in screen and b"Outside window" not in screen
        assert history.read_bytes() == before
        os.write(master, b"\x1b")
        receive_frame(master, b"Stopped")
        os.write(master, b"1")
        receive_frame(master, b"Active: Work")
        os.write(master, b"d")
        live_screen = receive_frame(master, b"Daily summaries")
        assert b"in progress" in live_screen
        receive_frame(master, b"00:00:01  Work")
        os.write(master, b"q")  # Clean quit from a summary still saves the live session.
        receive(master, b"\x1b[?25h\x1b[?1049l")
        assert process.wait(timeout=5) == 0, process.stderr.read()
        assert termios.tcgetattr(master) == original
        assert json.loads(history.read_text().splitlines()[-1])["change"]["stop"]["duration_ns"] >= 1_000_000_000
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        os.close(master)
        os.close(slave)

# Configured-zone totals include removed activities, exclude yesterday, and survive restart.
with tempfile.TemporaryDirectory(prefix="bad-timer-totals-") as directory:
    history = Path(directory) / "history.jsonl"
    config = Path(directory) / "config.json"
    zone = ZoneInfo("Pacific/Kiritimati")
    midnight = datetime.now(zone).replace(hour=0, minute=0, second=0, microsecond=0)
    config.write_text(json.dumps({"time_zone": zone.key, "activities": [{"id": "work", "name": "Work"}]}))
    events = []
    monday = midnight - timedelta(days=midnight.weekday())
    for session_id, date, name in ((1, midnight, "Removed"), (2, midnight - timedelta(days=1), "Yesterday"),
                                   (3, monday - timedelta(days=1), "Last week")):
        activity = {"id": name.lower(), "name": name}
        start_ns = int(date.timestamp()) * 1_000_000_000
        events.extend([
            {"version": 1, "change": {"start": {"session_id": session_id, "activity": activity, "start_utc_ns": start_ns}}},
            {"version": 1, "change": {"stop": {"session_id": session_id, "activity": activity, "end_utc_ns": start_ns, "duration_ns": 7_000_000_000}}},
        ])
    history.write_text("".join(json.dumps(event) + "\n" for event in events))
    for restart in (False, True):
        if restart:
            config.write_text(json.dumps({"time_zone": zone.key, "activities": [{"id": "work", "name": "Renamed work"}]}))
        process, master, slave, original = launch(args=("--config", str(config), "--history", str(history)))
        try:
            screen = receive(master, b"\x1b[?7h")
            assert b"bad-timer | Pacific/Kiritimati" in screen
            assert b"00:00:07  00:00:07  Removed" in screen and b"Last week" not in screen
            assert b"This week" in screen
            if midnight.weekday() == 0:
                assert b"Yesterday" not in screen
            else:
                assert b"00:00:00  00:00:07  Yesterday" in screen
            assert b"Last key" not in screen and b"columns x" not in screen
            assert b"Key  Today" in screen
            if not restart:
                before = history.read_bytes()
                os.write(master, b"1")
                running = receive(master, b"> 1  00:00:01  00:00:01  Work")
                if b"\x1b[?7h" not in running[running.index(b"> 1  00:00:01  00:00:01  Work"):]:
                    receive(master, b"\x1b[?7h")
                os.write(master, b"1")
                stopped = receive(master, b"\x1b[?7h")
                assert b"Stopped" in stopped
                assert history.read_bytes().startswith(before)
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 12, 40, 0, 0))
                process.send_signal(signal.SIGWINCH)
                narrow = receive_frame(master, b"week: enlarge")
                assert b"This week" not in narrow and b"00:00:07  Removed" in narrow
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 3, 20, 0, 0))
                process.send_signal(signal.SIGWINCH)
                small = receive(master, b"\x1b[?7h")
                assert b"More rows: enlarge terminal" in small
                assert b"\x1b[3;1Hd/w sums a menu q" in small
                assert b"\x1b[4;1H" not in small
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 1, 5, 0, 0))
                process.send_signal(signal.SIGWINCH)
                tiny = receive(master, b"\x1b[?7h")
                assert b"\x1b[1;1Ha e q" in tiny and b"\x1b[2;1H" not in tiny
                assert process.poll() is None
            else:
                assert b"00:00:00  Renamed work" not in screen
                assert screen.count(b"Renamed work") == 1 and b"  Work" not in screen
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
        receive(master, b"\x1b[?7h")
        os.write(master, b"e")
        screen = receive(master, b"\x1b[?7h")
        assert b"\x1b[23;1HExported completed sessions to ./bad-timer-2.csv" in screen
        assert b"\x1b[24;1H1-9: toggle" in screen
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
        receive(master, b"\x1b[?7h")
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
        receive(master, b"\x1b[?7h")
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
        receive(master, b"\x1b[?7h")
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

# Start/switch zones survive restart and later configuration changes.
with tempfile.TemporaryDirectory(prefix="bad-timer-session-zones-") as directory:
    root = Path(directory)
    config = root / "config.json"
    zoned = root / "history.jsonl"
    for index, zone_name in enumerate(("America/Los_Angeles", "Asia/Tokyo")):
        config.write_text(json.dumps({"time_zone": zone_name, "activities": [
            {"id": "work", "name": "Work"}, {"id": "rest", "name": "Rest"}]}))
        prefix = zoned.read_bytes() if zoned.exists() else b""
        process, master, slave, original = launch(args=("--config", str(config), "--history", str(zoned)))
        try:
            receive_frame(master, b"Stopped")
            os.write(master, b"1")
            receive_frame(master, b"Active: Work")
            os.write(master, b"2")
            receive_frame(master, b"Active: Rest")
            os.write(master, b"q")
            receive(master, b"\x1b[?25h\x1b[?1049l")
            assert process.wait(timeout=5) == 0, process.stderr.read()
            assert termios.tcgetattr(master) == original
            saved = zoned.read_bytes()
            assert saved.startswith(prefix)
            events = [json.loads(line) for line in saved[len(prefix):].splitlines()]
            assert all(event["version"] == 2 for event in events)
            assert events[0]["change"]["start"]["time_zone"] == zone_name
            assert events[1]["change"]["switch_activity"]["start"]["time_zone"] == zone_name
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            os.close(master)
            os.close(slave)

# Legacy unfinished sessions get a single durable assignment before terminal setup.
with tempfile.TemporaryDirectory(prefix="bad-timer-legacy-zone-") as directory:
    root = Path(directory)
    config = root / "config.json"
    legacy = root / "history.jsonl"
    old_start = (json.dumps({"version": 1, "change": {"start": {
        "session_id": 7, "activity": {"id": "removed", "name": "Old name"}, "start_utc_ns": 100}}}) + "\n").encode()
    config.write_text(json.dumps({"time_zone": "Asia/Tokyo", "activities": [{"id": "work", "name": "Work"}]}))
    for failure in (True, False):
        legacy.write_bytes(old_start)
        process, master, slave, original = launch(args=("--config", str(config), "--history", str(legacy)),
                                                   file_size_limit=len(old_start) if failure else None)
        try:
            if failure:
                assert process.wait(timeout=5) == 1
                diagnostic = process.stderr.read()
                assert b"timezone assignment failed" in diagnostic and b"disk may contain" in diagnostic
                assert legacy.read_bytes() == old_start
            else:
                receive_frame(master, b"Unfinished session 7")
                migrated = legacy.read_bytes()
                assert migrated.startswith(old_start)
                assert json.loads(migrated[len(old_start):]) == {"version": 2, "change": {"legacy_timezone": "Asia/Tokyo"}}
                os.write(master, b"q")
                receive(master, b"\x1b[?25h\x1b[?1049l")
                assert process.wait(timeout=5) == 0, process.stderr.read()
            assert termios.tcgetattr(master) == original
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            os.close(master)
            os.close(slave)
    config.write_text(json.dumps({"time_zone": "America/Los_Angeles", "activities": [{"id": "work", "name": "Work"}]}))
    process, master, slave, original = launch(args=("--config", str(config), "--history", str(legacy)))
    try:
        receive_frame(master, b"Unfinished session 7")
        assert legacy.read_bytes() == migrated, "legacy timezone was reassigned"
        os.write(master, b"q")
        receive(master, b"\x1b[?25h\x1b[?1049l")
        assert process.wait(timeout=5) == 0, process.stderr.read()
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        os.close(master)
        os.close(slave)

# Recovery is explicit, append-only, and independent of the current activity config.
start = json.dumps({"version": 2, "change": {"start": {
    "session_id": 7, "activity": {"id": "removed", "name": "Old name"},
    "start_utc_ns": 100, "time_zone": "UTC",
}}}).encode() + b"\n"
for action in (b"q", b"\x03", signal.SIGTERM, b"d", "write_failure"):
    history.write_bytes(start)
    process, master, slave, original = launch(
        args=("--history", str(history)),
        file_size_limit=len(start) if action == "write_failure" else None,
    )
    try:
        receive_frame(master, b"q / Ctrl-C: exit without changing history")
        for key in (b"1", b"a", b"\r"):  # Unrelated keys cannot resolve recovery.
            os.write(master, key)
            receive_frame(master, b"Unfinished session 7")
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
                receive(master, b"\x1b[?7h")
                saved = history.read_bytes()
                assert saved.startswith(start)
                assert json.loads(saved[len(start):]) == {
                    "version": 2, "change": {"discard": {"session_id": 7}}
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
        receive(master, b"\x1b[?7h" if action == b"d" else b"Unfinished session 7")
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
        initial = receive_frame(master, b"t: supply UTC end time")
        assert b"Activity: Old name" in initial
        assert b"Start UTC: 1970-01-01T00:00:00.000000100Z" in initial
        assert b"No time will be counted automatically." in initial
        os.write(master, b"u-1s\r" if duration_input else b"t1969-12-31T23:59:59Z\r")
        receive(master, b"Invalid duration" if duration_input else b"Invalid end time")
        assert history.read_bytes() == start
        if duration_input:
            os.write(master, b"\x1bu" + b"0s" * 128 + b"1h\r")
            receive_frame(master, b"Invalid duration")
            assert history.read_bytes() == start
        os.write(master, "\x1bu1µs2.5ms\r".encode() if duration_input else b"\x1bt1970-01-01T00:00:01Z\r")
        review = receive_frame(master, b"y: confirm and save")
        assert b"Unix nanoseconds" not in review
        if duration_input:
            assert b"End UTC: 1970-01-01T00:00:00.002501100Z" in review
            assert b"Recovery duration: 00:00:00.002501000" in review
        else:
            assert b"End UTC: 1970-01-01T00:00:01.000000000Z" in review
            assert b"Recovery duration: 00:00:00.999999900" in review
            assert b"Based on wall-clock timestamps, not measured elapsed time." in review
        assert history.read_bytes() == start
        if action == "save":
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 4, 30, 0, 0))
            process.send_signal(signal.SIGWINCH)
            small = receive_frame(master, b"Enlarge terminal to review")
            assert b"\x1b[4;1HEsc: back | q: quit" in small
            assert b"y: confirm and save" not in small and b"\x1b[5;1H" not in small
            os.write(master, b"y")
            receive_frame(master, b"Enlarge terminal to review")
            assert history.read_bytes() == start, "must not confirm hidden recovery details"
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
            process.send_signal(signal.SIGWINCH)
            receive_frame(master, b"y: confirm and save")
        if action in ("save", "failure"):
            os.write(master, b"y")
            if action == "save":
                receive(master, b"\x1b[?7h")
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
        receive(master, b"\x1b[?7h" if action == "save" else b"Unfinished session 7")
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
        screen = receive(master, b"\x1b[?7h")
        assert b"Last key" not in screen and b"controls ready" not in screen
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        os.kill(process.pid, signal.SIGWINCH)
        screen = receive(master, b"\x1b[?7h")
        assert b"\x1b[30;1H1-9: toggle" in screen
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
        receive(master, b"  2  00:00:00  00:00:00  Rest")
        for key, marker in ((b"1", b"Active: Work"), (b"2", b"Active: Rest"),
                            (b"2", b"Stopped"), (b"1", b"Active: Work")):
            os.write(master, key)
            receive(master, marker)
        receive(master, b"Elapsed: 00:00:01")
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
    {"id": str(i), "name": f"Activity {i}" + ("界" * 80 + "\x1b[2J" if i == 12 else "")} for i in range(1, 13)]}))
menu_history = Path(HOME.name) / "menu.jsonl"
process, master, slave, original = launch(args=("--config", str(menu_config), "--history", str(menu_history)))
try:
    screen = receive(master, b"\x1b[?7h")
    assert b"  9  00:00:00  00:00:00  Activity 9" in screen
    assert b"  -  00:00:00  00:00:00  Activity 10" in screen
    os.write(master, b"1")
    receive(master, b"Active: Activity 1")
    saved = menu_history.read_bytes()
    os.write(master, b"a")
    screen = receive_frame(master, b"> 1  [running] Activity 1")
    assert b"Activities 1/12 | ^0 v0" in screen
    assert b"\x1b[24;1HUp/Down: move | Enter: toggle | Esc: back" in screen
    # Fragmented CSI and application-cursor arrows are both accepted.
    os.write(master, b"\x1b")
    time.sleep(0.01)
    os.write(master, b"[B")
    screen = receive_frame(master, b"> 2  Activity 2")
    assert b"  1  [running] Activity 1" in screen and screen.count(b"[running]") == 1
    os.write(master, b"\x1bOA")
    receive_frame(master, b"> 1  [running] Activity 1")
    os.write(master, b"\x1b")
    receive_frame(master, b"Active: Activity 1")
    assert menu_history.read_bytes() == saved, "cancel changed timing"
    os.write(master, b"a")
    receive_frame(master, b"> 1  [running] Activity 1")
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 4, 40, 0, 0))
    os.kill(process.pid, signal.SIGWINCH)
    screen = receive_frame(master, b"> 1  [running] Activity 1")
    assert b"Activities 1/12 | ^0 v10" in screen
    for i in range(2, 11):
        os.write(master, b"\x1b[B")
        screen = receive_frame(master, f"> {i if i <= 9 else '-'}  Activity {i}".encode())
    assert b"Activity 1\x1b" not in screen, "menu did not scroll"
    assert b"Activities 10/12 | ^8 v2" in screen
    assert b"\x1b[4;1HUp/Down Enter Esc: back" in screen
    assert b"> 10" not in screen, "position must not look like a numeric shortcut"
    # At one row selection wins over chrome; every item remains reachable.
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 1, 20, 0, 0))
    os.kill(process.pid, signal.SIGWINCH)
    receive_frame(master, b"> 10/12 -  Activity 10")
    for i in (11, 12):
        os.write(master, b"\x1b[B")
        screen = receive_frame(master, f"> {i}/12 -  Activity {i}".encode())
        assert b"\x1b[2;1H" not in screen
    assert b"?[2J" in screen and b"\x1b[2J" not in screen[screen.index(b"Activity 12"):]
    os.write(master, b"\x1b[B")
    receive_frame(master, b"> 12/12 -  Activity 12")
    os.write(master, b"\x1b[A")
    receive_frame(master, b"> 11/12 -  Activity 11")
    os.write(master, b"\x1b[A")
    receive_frame(master, b"> 10/12 -  Activity 10")
    assert menu_history.read_bytes() == saved, "menu navigation changed history"
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 2, 20, 0, 0))
    os.kill(process.pid, signal.SIGWINCH)
    screen = receive_frame(master, b"> 10/12 -  Activity 10")
    assert b"\x1b[2;1H^v Ent Esc" in screen
    os.write(master, b"\r")
    receive_frame(master, b"More rows: enlarge terminal")
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    os.kill(process.pid, signal.SIGWINCH)
    receive_frame(master, b"Active: Activity 10")
    os.write(master, b"a")
    screen = receive_frame(master, b"> 1  Activity 1")
    assert b"  -  [running] Activity 10" in screen
    for i in range(2, 11):
        os.write(master, b"\x1b[B")
        receive_frame(master, (f"> {i}  Activity {i}" if i <= 9 else "> -  [running] Activity 10").encode())
    os.write(master, b"\r")
    receive_frame(master, b"Stopped")
    os.write(master, b"a")
    screen = receive_frame(master, b"> 1  Activity 1")
    assert b"[running]" not in screen
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
    receive(master, b"\x1b[?7h")
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
