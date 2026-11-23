# bad-timer

A keyboard-driven workday timer, currently at the terminal-foundation stage.
**Activity tracking, configuration, storage, and CSV export are not implemented.**
See `PLAN.md` for approved scope and the per-step review gate.

## Build and run

Requires macOS, Zig **0.17.1**, and Ghostty with its default
`TERM=xterm-ghostty`. Other platforms/terminals are not supported. Startup
requires both stdin and stdout to be TTYs and checks `TERM`; this is a capability
marker, not proof that the terminal actually is Ghostty.

```sh
zig build
zig build run
# Or run ./zig-out/bin/bad_timer directly in Ghostty.
zig build test
zig fmt --check build.zig src
zig build -Doptimize=ReleaseSmall
python3 tests/terminal_smoke.py
```

The screen shows terminal dimensions and the last input byte. Press any key to
exercise immediate input; `q` or Ctrl-C quits. Resize redraws the screen. There
is no timer yet. Input is byte-based; escape sequences and Unicode decoding
will be added only as required by later approved UI work.

Uses macOS libc APIs via Zig's build-time C translation, with no third-party
dependencies. Input waits in `select` with a one-second timeout, not busy polling;
idle timeouts do not redraw or write files. SIGINT, SIGTERM, SIGHUP, and SIGQUIT
unwind the screen and restore termios. Ctrl-Z suspension is disabled while the
screen is active. SIGKILL, crashes, or terminal disconnection cannot guarantee
screen cleanup; use `stty sane` and `reset` if necessary.

## Verification

The Python smoke test uses macOS pseudo-terminals to check input, resize, no
idle redraw, quit/Ctrl-C/signals, runtime output-disconnection errors, termios
restoration, and rejection of non-TTY/unsupported-terminal startup. It requires
Python 3 and is separate from `zig build test`.

A real Ghostty smoke test is still required: run the app, press a key, resize
(including a very small window), quit with `q`, repeat with Ctrl-C, and confirm
the shell's echo, cursor, screen, and input work normally afterward. PTY checks
do not establish visual correctness in Ghostty. Suspend/elapsed-clock behavior
is not part of this foundation step and has not been tested.
