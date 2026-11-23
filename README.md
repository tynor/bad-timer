# bad-timer

A keyboard-driven workday timer, currently at the terminal-foundation stage.
**Interactive activity tracking, transition persistence, and CSV export are not implemented.**
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
is no timer yet; history is loaded and locked at startup. Input is byte-based; escape sequences and Unicode decoding
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
sessions; the timer itself performs no I/O or clock acquisition. Durability, totals, and UI integration remain separate work.

`src/clock.zig` provides `clock.now() !Instant` using macOS `clock_gettime`:
`CLOCK_MONOTONIC_RAW` for elapsed nanoseconds and `CLOCK_REALTIME` for Unix UTC
nanoseconds. The installed macOS manual documents RAW as unadjusted and
suspend-inclusive (unlike `CLOCK_UPTIME_RAW`). These are sequential reads, not
an atomic snapshot; scheduling delays can separate them. UTC remains reporting
metadata and may jump without changing elapsed duration. OS read failures return
`ClockReadFailed`; invalid or unrepresentable readings return
`ClockReadingOutOfRange`. No fabricated reading or fallback clock is returned.
The adapter is exported but is not yet called by the terminal executable.
Tests cover nanosecond conversion, pre-epoch UTC, invalid readings, OS read
failure, and feeding live readings into a timer.

Manual suspend acceptance remains pending: in a temporary caller of
`clock.now()`, record a reading before sleep and another after resume. Suspend
the Mac for a measured interval (for example, at least 30 seconds), then check
that the monotonic delta includes that interval rather than only awake time.
Also compare with an awake-only interval. Do not change the system wall clock
for this check. Record macOS version and measured deltas; the automated tests
neither suspend the host nor prove real suspend behavior.

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

## In-memory history codec

`src/history.zig` encodes version-1 JSON Lines events and replays them entirely
in memory. `encode` returns an allocated LF-terminated record. Each event has
required `version` and `change` fields; `change` contains exactly one `start`,
`stop`, `switch_activity`, or `discard` value. Starts carry a positive, strictly increasing
`session_id`, an activity ID/name snapshot, and `start_utc_ns`. Stops carry the
same session ID and activity snapshot, `end_utc_ns`, and `duration_ns`. A switch
contains both stop and start, with matching UTC boundary and different activity
IDs. UTC timestamps are signed integer Unix nanoseconds; durations are unsigned
monotonic elapsed nanoseconds, not computed from UTC endpoints. Backwards UTC
is allowed. A discard carries only a positive `session_id`, which must match the
unfinished session. It clears that session without adding completed time or
removing any prior records. Session IDs cannot be reused, including after a stop
or discard. Older binaries that do not recognize discard events reject such logs;
use a binary with discard support once these events have been written.

`History.replay` owns its strings and completed sessions independently of the
input or current config; call `deinit` once and do not copy it. `unfinished`
retains a final unmatched start without creating a completed session. Renaming
or removing configured activities cannot change these snapshots. Empty input
is valid. Malformed JSON, unknown/duplicate/missing fields, unsupported versions,
invalid identities/transitions, blank records, and a missing final LF reject the
whole input. No records are skipped, repaired, or truncated. Encoding validates
individual records; replay and append preparation also check preceding transitions.

Tests cover round trips, escaped/Unicode names, ownership, atomic switches,
unfinished sessions, backwards wall clocks, corruption, and invalid transitions.
The codec itself performs no I/O. Storage uses it for startup replay and transition
preparation. Recovery prompts are not implemented. Replay currently retains the entire history in
memory; it does not stream or impose a file-size limit.

## History file loading and durable appends

The default history path is `$HOME/Library/Application Support/bad-timer/history.jsonl`.
Use `--history PATH` to override it (relative paths use the working directory).
Flags may appear in either order; duplicate, empty, or missing values are rejected.
Example: `zig build run -- --config ./activities.json --history ./history.jsonl`.
The parent directory must already exist, including for overrides. No directories
are created automatically. A missing file is created with mode `0600` (subject
to umask); existing permissions and contents are unchanged.

After config validation and before terminal setup, `src/storage.zig` opens the
file without truncation, takes a nonblocking exclusive advisory lock, and replays
all records. The lock lasts until exit; another cooperating process using the
same file is rejected. Do not replace/delete a locked file or edit it while the
app runs: locks protect the open file, not its pathname, and unrelated tools
can ignore advisory locks. Local macOS filesystems are the intended target.

Corrupt or incomplete input aborts startup with its path and reason, without
repair, truncation, or skipped records. Preserve the file for future recovery.
An unfinished session opens a recovery prompt showing its session ID. Press `d`
to explicitly discard it without adding completed time, or `q` / Ctrl-C to exit
without changing history. Press `t` to enter an end time as `YYYY-MM-DDTHH:MM:SSZ`
(explicit UTC, whole seconds, years 0001–9999). Backspace edits; Enter validates
and shows the inferred duration; `y` confirms and saves. Escape cancels entry or
confirmation without writing. End times before the start, invalid calendar dates,
and durations exceeding the stored `u64` nanosecond range are rejected.
Recovery infers duration from UTC timestamps, not a surviving monotonic reading;
wall-clock changes during the interrupted session cannot be reconstructed. Review
that estimate before confirming. Discard or confirmed stop is persisted and synced
before the foundation screen appears; restarting then opens stopped. Both append
without rewriting original records and use the historical activity name/ID.
Timer controls remain disabled. Loading retains
the entire history in memory without a size limit. `Store.deinit` releases both
the owned history and file lock; do not copy the owning store.

`Store.append` validates a transition and reserves memory before writing one
LF-terminated event at the tracked end of the locked file. It syncs the file
before committing the in-memory state or returning success. Start, stop,
switch, and discard use the same path; each transition is one record. Discard is
also available in the startup recovery prompt. It appends a record
without rewriting the original start or any completed sessions. Callers must not mutate the
store's history directly or write the file through another handle.

Validation/allocation failures leave logical state and file contents unchanged.
A write or sync failure leaves the previous logical state intact and blocks all
further appends on that store (`HistoryWriteBlocked`). Report the original error
as uncertain: part or all of the event may be on disk, even after a sync failure.
Do not retry blindly. Close and reopen to replay what is present; incomplete or
corrupt bytes still abort startup and must be preserved for future recovery.
The recovery prompt exits on append failure with the history path and an uncertainty
warning; it does not retry or claim recovery succeeded. Activity controls remain disconnected.

Tests cover durable start/switch/stop/discard, preserved original bytes, discarded
session IDs remaining consumed, rejected transitions without file changes,
injected partial-write/sync failures, blocked retries, and restart uncertainty.
Tests also cover creation, lock release, replay across reopen, completed/unfinished
sessions, process exclusion, restrictive creation permissions, access errors,
and preservation of corrupt bytes and terminal settings. PTY checks cover recovery
cancel/interruption, ignored keys, durable discard and confirmed end-time recovery,
invalid end times, restart, and file-size-limit write failures with terminal cleanup.
Deterministic recovery tests cover calendar validation, epoch conversion, and duration bounds.

## Configuration

The executable reads `$HOME/Library/Application Support/bad-timer/config.json`
by default. Use `--config PATH` to load a different file; relative paths resolve
from the working directory. Each override bypasses `HOME` for that path and never falls back on failure.
Supply both `--config PATH` and `--history PATH` to run without `HOME`. Repeat flags, unknown arguments, and
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
do not establish visual correctness in Ghostty. Real suspend/elapsed-clock behavior
has not been manually tested; the isolated clock adapter does not establish it.
