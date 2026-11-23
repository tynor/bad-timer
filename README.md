# bad-timer

A keyboard-driven workday timer, currently at the terminal-foundation stage.
**Interactive activity tracking, storage, and CSV export are not implemented.**
An isolated in-memory timer state module is implemented and tested; it is not yet
connected to the terminal. An isolated macOS time-zone helper is also implemented
and tested. JSON config is loaded and validated at startup; daily totals and
activity controls are not yet wired up.
See `PLAN.md` for approved scope and the per-step review gate.

## Build and run

Requires macOS, Zig **0.17.1**, and Ghostty with its default
`TERM=xterm-ghostty`. Other platforms/terminals are not supported. Startup
requires both stdin and stdout to be TTYs and checks `TERM`; this is a capability
marker, not proof that the terminal actually is Ghostty.

Before running, create `$HOME/Library/Application Support/bad-timer/config.json`
using the example below, or pass `--config PATH`. The app does not create a default config.

```sh
zig build
zig build run
# Or use a different config:
zig build run -- --config ./activities.json
# Or run ./zig-out/bin/bad_timer --config ./activities.json in Ghostty.
zig build test
zig fmt --check build.zig src
zig build -Doptimize=ReleaseSmall
python3 tests/terminal_smoke.py
```

The screen shows terminal dimensions and the last input byte. Press any key to
exercise immediate input; `q` or Ctrl-C quits. Resize redraws the screen. There
is no timer yet. Input is byte-based; escape sequences and Unicode decoding
will be added only as required by later approved UI work.

Uses macOS libc and CoreFoundation APIs via Zig's build-time C translation, with no third-party
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

`zig build test` covers the timer's start/stop, same-ID toggle, gap-free switching,
zero-duration sessions, and wall-clock jumps. `src/root.zig` takes injected
monotonic and UTC nanosecond readings; duration uses only monotonic time. UTC
endpoints are retained unchanged, even if a clock correction puts the end before
the start. Readings before the running session's monotonic start are rejected
without changing state. Activity IDs/names are borrowed immutable strings that
must outlive the timer and returned sessions. The caller retains completed
sessions; the module performs no I/O or clock acquisition. Durability, totals, and UI integration remain separate work.

`src/time_zone.zig` uses CoreFoundation's system IANA zone list and Gregorian
calendar, without changing process-global `TZ`. Omitted zones default to `UTC`;
empty, malformed, and unknown identifiers are rejected. Its owned calendar must
be released with `deinit` and not copied. `dayAt` takes integer Unix UTC seconds
and returns a local date plus a half-open UTC day interval; this is not duration
accounting and does not yet split sessions or compute totals. It accepts seconds
from -62135510400 through 253402214399 (a conservative range within years 1–9999).
Tests cover UTC, pre-epoch time, local midnight, independent zones, invalid input,
and Los Angeles's 23-hour/25-hour days in 2024. Rules come from the installed
macOS time-zone database and may change with OS updates.

## Configuration

The executable reads `$HOME/Library/Application Support/bad-timer/config.json`
by default. Use `--config PATH` to load a different file; relative paths resolve
from the working directory. An override does not require `HOME`, and a failed
override never falls back to the default. Repeat flags, unknown arguments, and
missing or empty paths are rejected with usage guidance.

The file is read once at startup, after checking the terminal but before changing
terminal state. Without an override, `HOME` must be an absolute path. Missing, unreadable, oversized (over 1 MiB), or
invalid files cause an error with the path and reason. No file or directory is
created or modified. Fix the file and restart; there is no live reload.

`src/config.zig` parses this JSON shape:

```json
{
  "activities": [
    { "id": "work", "name": "Work" },
    { "id": "break", "name": "Break" }
  ],
  "time_zone": "America/Los_Angeles"
}
```

`time_zone` defaults to `UTC` when omitted; explicit null, empty, or unknown
zones are rejected. At least one activity is required. IDs must be unique and
nonblank; names must be nonblank (blank means only ASCII spaces, tabs, CR, or LF).
Strings are preserved without trimming; IDs are case-sensitive. Malformed JSON,
missing required fields, wrong types, duplicate fields, and unknown fields are
rejected. Config order assigns numeric keys `1`–`9`; later activities are retained
in order without numeric keys for the future menu. Reordering never changes IDs.

`Config.parse` owns its strings independently of the input buffer. Call `deinit`
once and do not copy the owning config. Activities borrowed by timers or sessions
must not outlive it. Tests cover ownership, validation failures, default/explicit
zones, and key assignment with fewer and more than nine activities. `Config.load`
reads a file using the same parser and returns the same owned configuration.
The PTY smoke tests use a temporary home and cover successful startup plus missing,
unreadable, malformed, invalid, and oversized config failures, checking that errors
leave terminal settings and file contents unchanged. They also cover absolute and
relative config overrides without `HOME`, override failures, and invalid arguments.
The loaded activities are not
yet displayed or selectable.

A real Ghostty smoke test is still required: run the app, press a key, resize
(including a very small window), quit with `q`, repeat with Ctrl-C, and confirm
the shell's echo, cursor, screen, and input work normally afterward. PTY checks
do not establish visual correctness in Ghostty. Suspend/elapsed-clock behavior
is not part of this foundation step and has not been tested.
