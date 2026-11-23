"""macOS size/history checks; run after zig build -Doptimize=ReleaseSmall.

Uses a private PTY/config/history. Does not measure CPU or RSS (no ps).
"""
import csv
import errno
import fcntl
import json
import os
from pathlib import Path
import platform
import pty
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time

EXE = Path("zig-out/bin/bad_timer").resolve()
IDLE_SECONDS = 5


def receive(fd, needle):
    data = b""
    deadline = time.monotonic() + 5
    while needle not in data and time.monotonic() < deadline:
        if select.select([fd], [], [], 0.1)[0]:
            try:
                chunk = os.read(fd, 8192)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                break
            if not chunk:
                break
            data += chunk
    assert needle in data, (needle, data)
    return data


def idle(fd, process, history):
    before = history.read_bytes(), history.stat().st_mtime_ns
    deadline = time.monotonic() + IDLE_SECONDS
    while time.monotonic() < deadline:
        assert process.poll() is None, process.stderr.read()
        if select.select([fd], [], [], 0.1)[0]:
            assert os.read(fd, 8192), "terminal closed during idle check"
    assert process.poll() is None
    assert (history.read_bytes(), history.stat().st_mtime_ns) == before, "idle history changed"


def main():
    if sys.platform != "darwin":
        raise SystemExit("This check requires macOS.")
    with tempfile.TemporaryDirectory(prefix="bad-timer-resources-") as directory:
        root = Path(directory)
        config = root / "config.json"
        history = root / "history.jsonl"
        config.write_text(json.dumps({"activities": [
            {"id": "work", "name": "Work"}, {"id": "break", "name": "Break"},
        ]}))
        master, slave = pty.openpty()
        original = termios.tcgetattr(slave)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))

        def controlling_terminal():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

        process = None
        try:
            process = subprocess.Popen(
                [str(EXE), "--config", str(config), "--history", str(history)],
                stdin=slave, stdout=slave, stderr=subprocess.PIPE,
                env=dict(os.environ, TERM="xterm-ghostty", HOME=directory),
                cwd=directory, preexec_fn=controlling_terminal,
            )
            receive(master, b"\x1b[?7h")
            sizes = {"initial": history.stat().st_size}
            assert sizes["initial"] == 0
            idle(master, process, history)
            for key, state, label in ((b"1", b"Active: Work", "start"),
                                      (b"2", b"Active: Break", "switch"),
                                      (b"2", b"Stopped", "stop")):
                os.write(master, key)
                receive(master, state)
                sizes[label] = history.stat().st_size
                idle(master, process, history)
            changes = [json.loads(line)["change"] for line in history.read_text().splitlines()]
            assert [list(change) for change in changes] == [["start"], ["switch_activity"], ["stop"]]
            assert sizes["initial"] < sizes["start"] < sizes["switch"] < sizes["stop"]
            before = history.read_bytes(), history.stat().st_mtime_ns
            os.write(master, b"e")
            receive(master, b"Exported completed sessions to ./bad-timer-1.csv")
            with (root / "bad-timer-1.csv").open(newline="") as report:
                rows = list(csv.reader(report))
            assert len(rows) == 3 and [row[0] for row in rows[1:]] == ["work", "break"]
            os.write(master, b"q")
            receive(master, b"\x1b[?25h\x1b[?1049l")
            assert process.wait(timeout=5) == 0, process.stderr.read()
            assert termios.tcgetattr(master) == original
            assert (history.read_bytes(), history.stat().st_mtime_ns) == before
            print(json.dumps({
                "machine": platform.machine(), "macos": platform.mac_ver()[0],
                "binary_bytes": EXE.stat().st_size,
                "idle_seconds_per_phase": IDLE_SECONDS,
                "idle_phases": ["initial stopped", "running work", "running break", "stopped"],
                "idle_history_content_and_mtime_unchanged": True,
                "history_bytes": sizes, "completed_sessions": len(rows) - 1,
                "cpu_and_rss": "not measured (ps-dependent checks skipped)",
            }, indent=2))
        finally:
            if process is not None and process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            os.close(master)
            os.close(slave)


if __name__ == "__main__":
    main()
