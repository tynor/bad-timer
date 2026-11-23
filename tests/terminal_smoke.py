"""macOS PTY checks; run after zig build: python3 tests/terminal_smoke.py."""
import errno
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import termios
import time

EXE = "./zig-out/bin/bad_timer"
ENV = dict(os.environ, TERM="xterm-ghostty")


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


def launch(output=None):
    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))

    def controlling_terminal():
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

    process = subprocess.Popen(
        [EXE], stdin=slave, stdout=slave if output is None else output,
        stderr=subprocess.PIPE, env=ENV, preexec_fn=controlling_terminal,
    )
    return process, master, slave, original


for exit_key in (b"q", b"\x03", signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT):
    print("checking", repr(exit_key), flush=True)
    process, master, slave, original = launch()
    try:
        receive(master, b"No timer or storage yet.")
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
    receive(out_master, b"No timer or storage yet.")
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
print("terminal smoke checks passed")
