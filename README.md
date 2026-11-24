# bad-timer

## Native macOS app (first slice)

With Zig 0.17.1 and Swift/Xcode command-line tools installed:

```sh
sh macos/build.sh
open "build/Bad Timer.app"
# Bridge integration tests (temporary config/history only):
python3 tests/native_smoke.py
```

The small SwiftUI window lists configured activities and live elapsed time.
Click to start, click the running activity to stop, or another to switch atomically.
Normal Quit/window-close saves the running session. The app links the existing Zig
clock, config, history, and shared durable-transition implementation; it does not
reimplement timing or write JSON history in Swift.

It uses the same `$HOME/Library/Application Support/bad-timer/config.json` and
`history.jsonl` as the TUI; create the config and parent directory as described
below. Exclusive locking prevents concurrent app/TUI writers. For isolated testing,
launch `build/Bad Timer.app/Contents/MacOS/BadTimer` directly with
`BAD_TIMER_CONFIG` and `BAD_TIMER_HISTORY` environment overrides.
Unfinished history blocks startup without modification: recover using the TUI,
then restart the app. Corrupt history is never automatically repaired. After an
uncertain save failure, controls block retries; quit and inspect/recover history.
Force Quit/crashes leave explicit recovery for restart.

This is a local, unsigned app, not an App Store/sandboxed distribution. Native
recovery, totals/summary screens, config editing, and CSV controls are deferred;
they remain available in the TUI. App compilation, bridge replay/locking/transitions,
and existing unit/PTY checks were verified; interactive GUI behavior and older
macOS deployment were not verified. The current SDK may emit deployment-version
linker warnings when its version differs from the host Zig target.


A keyboard-driven workday timer with durable numeric-key activity tracking.
Keys `1`–`9` select activities in config order: start while stopped, stop the
same activity, or switch atomically to another. The screen shows keys, active
activity, and monotonic elapsed time as `HH:MM:SS` (hours can exceed 24).
Transitions are synced before display.
Press `a` for a scrolling menu of all activities, including those beyond nine.
Up/Down moves, Enter selects (with the same start/stop/switch behavior), and
Escape cancels without changing timing. Tracking continues while the menu is open.
The menu uses `>` for selection and a separate `[running]` label for the active
activity. Only actual numeric shortcuts are shown; `-` marks activities beyond nine.
The header shows selection position (`10/12`) and hidden-row counts (`^8 v2` means
8 above, 2 below). Navigation help stays at the bottom. On one- or two-row screens,
position moves beside the selected item; at one row help is omitted so selection
remains visible. Names clip without wrapping, and resizing preserves selection.
Press `e` outside menus/summaries to export completed sessions as CSV (details below).
Press `d` for daily summaries or `w` for weekly summaries (details below).
Today and This week totals include completed and running time in the configured
zone, shown as `HH:MM:SS` in one list alongside activity shortcuts. Weeks start
Monday at local midnight and end at the following Monday, including DST changes. `>` marks the
running activity without relying on color. Configured activities use their current
names; removed activities retain recorded names. `-` means no numeric shortcut
(use `a` for configured activities beyond nine). Configured activities with no
time today show zero.

```text
bad-timer | Dates: America/Los_Angeles
Active: Work
Elapsed: 00:42:10

Key  Today     This week  Activity (> running)
> 1  01:15:30  08:30:00  Work
  2  00:12:00  01:10:00  Break
  -  00:08:20  00:08:20  Old task

1-9: toggle | a: activities | d: days | w: weeks | e: export | q: quit
```

The controls footer stays at the bottom, with export status immediately above it.
Below 50 columns the week column is hidden; enlarge the terminal to see it.
Removed activities with time this week remain listed even if today's total is zero.
Small screens reduce the header and help text, clip rows without scrolling, and
show an enlargement hint. At extremely small sizes, controls/status take priority
(the `a` menu still reaches every configured activity).
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

`q`, Ctrl-C, and handled termination signals stop and save a running session.
Restart opens stopped. Unexpected terminal errors leave an unfinished session for
explicit recovery. Save failures exit with an uncertainty warning; preserve the
history and restart, rather than retrying. Resize redraws the screen; elapsed
seconds redraw only while running. Menu arrows accept CSI and application-cursor
sequences; a standalone Escape cancels after a 50 ms sequence timeout.
Config-name control bytes render as `?`, not terminal commands. Long menu names
are clipped at the terminal edge rather than wrapping; resize adjusts the visible list.

Uses macOS libc and CoreFoundation APIs via Zig's build-time C translation, with no third-party
dependencies. Input waits in `select` with a one-second timeout, not busy polling;
idle timeouts do not redraw or write files. Main, activity-menu, and recovery
redraws use Ghostty's synchronized-output mode (`CSI ? 2026 h/l`) to present each
redraw together instead of exposing intermediate clears/writes. The shared redraw
path ends synchronization and restores wrapping after each frame, attempts both
on redraw errors, and defensively resets both before leaving the alternate screen.
Output cleanup is best effort if the terminal has disconnected; SIGKILL/crashes
cannot guarantee it. PTY checks validate the protocol, but actual flicker improvement
still needs manual Ghostty review. SIGINT, SIGTERM, SIGHUP, and SIGQUIT
unwind the screen and restore termios. Ctrl-Z suspension is disabled while the
screen is active. SIGKILL, crashes, or terminal disconnection cannot guarantee
screen cleanup; use `stty sane` and `reset` if necessary.

## Resource checks

Run from the repository root (Python 3, with assertions enabled):

```sh
zig build -Doptimize=ReleaseSmall
python3 tests/resource_check.py
```

The script uses a private temporary config/history and a 24×80 macOS PTY, not
Ghostty. It reports the executable's on-disk size and history growth through
start → switch → stop → export → quit. It checks history contents and modification
time across four five-second no-input windows: initially stopped, each running
activity, and stopped again. It drains terminal output during those windows and
checks two exported sessions, transition records, clean exit, and termios cleanup.
This observes unchanged history, not an OS-level trace of every disk write.
Temporary files are removed; real user history is not accessed.

Measured on Apple M1 Max (arm64), macOS 27.2.1, Zig 0.17.1, ReleaseSmall:

| Measurement | Result |
| --- | ---: |
| Executable size (including saved-zone cutoff integration) | 279,912 bytes |
| Empty history | 0 bytes |
| After start | 155 bytes |
| After switch | 453 bytes |
| After stop (two completed sessions) | 601 bytes |
| History content/mtime changes during no-input windows | None |
| History changes from export and stopped quit | None |

History byte counts vary with timestamp/duration digit lengths and activity names.
An earlier summary-screen build measured 2,691,368 bytes; that result did not recur
in the latest ReleaseSmall verification. Its cause has not been investigated.
CPU and RSS measurements were **skipped at user request** after sandbox denial of
`ps`; the provisional <1% CPU and <20 MiB RSS targets remain unverified. This
script does not use `ps` or substitute another process-inspection mechanism.
Real Ghostty, suspend-clock behavior, and long-history resource scaling remain
unverified; these short, empty-history measurements are not a release certification.

## Verification

The Python smoke test uses macOS pseudo-terminals to check input, resize, no
idle redraw, quit/Ctrl-C/signals, runtime output-disconnection errors, termios
restoration, menu selection beyond nine, selection/running labels, shortcut display,
scroll counts, one-/two-row resize, long/control-containing names, cancellation,
durable menu start/stop/switch, and rejection of non-TTY/unsupported-terminal startup.
An incremental output-protocol checker handles split escape sequences, rejects
nested synchronized frames and unprotected clears, and checks synchronization
ends before wrapping is restored or the alternate screen is left (including
handled interruption and save-failure paths). It requires
Python 3 and is separate from `zig build test`.

`zig build test` covers the timer's start/stop, same-ID toggle, gap-free switching,
zero-duration sessions, and wall-clock jumps. `src/root.zig` takes injected
monotonic and UTC nanosecond readings; duration uses only monotonic time. UTC
endpoints are retained unchanged, even if a clock correction puts the end before
the start. Readings before the running session's monotonic start are rejected
without changing state. Activity IDs/names are borrowed immutable strings that
must outlive the timer and returned sessions. The caller retains completed
sessions; the timer itself performs no I/O or clock acquisition.

`src/clock.zig` provides `clock.now() !Instant` using macOS `clock_gettime`:
`CLOCK_MONOTONIC_RAW` for elapsed nanoseconds and `CLOCK_REALTIME` for Unix UTC
nanoseconds. The installed macOS manual documents RAW as unadjusted and
suspend-inclusive (unlike `CLOCK_UPTIME_RAW`). These are sequential reads, not
an atomic snapshot; scheduling delays can separate them. UTC remains reporting
metadata and may jump without changing elapsed duration. OS read failures return
`ClockReadFailed`; invalid or unrepresentable readings return
`ClockReadingOutOfRange`. No fabricated reading or fallback clock is returned.
The terminal executable uses this adapter for live timer transitions and elapsed display.
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
calendar, without changing process-global `TZ`. Configs with no zone resolve the
macOS system identifier once at startup, falling back to `UTC` if unavailable or
unsupported. Explicit empty, malformed, and unknown identifiers are rejected.
`systemName` returns an owned UTF-8 identifier; low-level `Zone.init(null)` still
explicitly selects UTC for deterministic callers. Its owned calendar must
be released with `deinit` and not copied. `dayAt` takes integer Unix UTC seconds
and returns a local date plus a half-open UTC day interval; this is not duration
accounting; `src/totals.zig` handles session attribution separately. It accepts seconds
from -62135510400 through 253402214399 (a conservative range within years 1–9999).
Tests cover UTC, pre-epoch time, local midnight, independent zones, invalid input,
and Los Angeles's 23-hour/25-hour days in 2024. Rules come from the installed
macOS time-zone database and may change with OS updates.

## Daily and weekly totals

`src/totals.zig` exposes `calculate(allocator, zone, sessions, live, now)` for the
display-zone date containing `now`, and `calculateWeek` with the same arguments
for the containing Monday–Sunday calendar week. The display zone supplies shared
date labels only (`Dates:` in the screen header). Each completed/live session's
saved `time_zone` supplies the UTC cutoffs for those labels; different zones are
not grouped into separate sections. For example, a session on Jan 1 in Tokyo can
count under Jan 1 even if its UTC timestamp is Dec 31. The same stable activity ID
can combine sessions from different zones. Live time can belong to the preceding
displayed day/week when the saved zone is still on Sunday/its previous date. `Zone.weekAt` uses CoreFoundation with
Monday fixed as the first weekday, independent of locale; a DST week can have
167 or 169 hours. Both use the same proportional attribution and cumulative
nanosecond rounding, including start-date attribution for zero/backward spans.
Weekly attribution is calculated directly over the whole week, not by rounding
each displayed day's seconds. The screen refreshes at local-day changes (including
Monday rollover), on timer ticks and transitions; there is no per-second idle redraw.
There is no arbitrary date navigation or week-start setting. History and CSV exports
remain unchanged; CSV still exports all completed session rows, not aggregates.
Tests cover Monday/Sunday boundaries, year rollover, configured-zone differences,
DST, boundary rounding, renames/removal, live Monday crossings, and clock jumps.

Both calculations combine completed sessions and live monotonic
elapsed time by stable activity ID, including activities removed from config.
Only nonzero totals appear, in first-contribution order, with the first contributing
session's borrowed ID/name (renames do not create a new activity). The caller frees
the result slice and keeps input strings alive. Durations accumulate as `u128`
nanoseconds with checked overflow; invalid query dates, allocation failures, and
regressing live monotonic readings return errors without changing inputs.
`calculateDates` applies an explicit half-open date-label range; cutoffs are cached
per distinct saved zone within each calculation. `calculateInterval` remains a
low-level fixed-UTC-interval API and does not reinterpret its boundaries. Unzoned
in-memory inputs use the display zone for compatibility; normal startup already
assigns legacy history a durable zone before any screen is drawn.
`Zone.intervalForDates` resolves real calendar boundaries, including repeated or
missing midnight; a whole skipped date contributes zero rather than aborting.
Tests cover mixed LA/Tokyo/UTC day and week cutoffs, year rollover, live saved-zone
Sunday versus display Monday, 23/25-hour days, 167/169-hour weeks, repeated midnight,
skipped dates, and conserved nanosecond rounding.

Positive UTC spans distribute measured duration proportionally across actual local
day boundaries, including DST. Cumulative integer rounding conserves nanoseconds
across adjacent days. Zero or backward UTC spans attribute all measured duration
to the start date. This is an attribution policy, not a reconstruction of when a
wall-clock adjustment occurred; history contains only endpoint readings. Neither
stored durations nor history bytes are changed. Tests cover midnight, fractional
pre-epoch times, 23/25-hour days, renames/removal, live time, empty input, clock
jumps, and timestamp extremes. The TUI shows the configured zone and these totals,
refreshing on live elapsed seconds, transitions, and local-day changes. Stopped,
unchanged screens do not redraw each second. PTY checks cover live updates,
restart, removed activities, configured-zone attribution, and small-screen resize.

## Daily and weekly summary screens

Outside the activity menu and recovery, `d` opens the last **7 days including
today**; `w` opens the last **4 Monday–Sunday weeks including this week**. Periods
appear newest first, labeled with configured-zone dates (weekly ranges show
Monday through Sunday). Each section shows a total and per-activity breakdown;
empty periods show zero and `No time recorded`. Current periods are labeled, with
`in progress` while a timer is running. Displayed totals sum exact nanoseconds
before formatting as whole-second HH:MM:SS, so fractional row rounding can differ
from the displayed grand total.

Up/Down scrolls all report rows; Esc returns to the timer. Timers continue running
and refresh the view each elapsed second. `q`/handled termination still stops and
saves live time. Activity/menu/export keys are ignored in summaries, so browsing
cannot change tracking or write history/reports. Header arrows show hidden-row
counts; small terminals reserve help space and allow scrolling to every row. At
one row only report content is shown. Resizing clamps the scroll position.

Configured activity IDs use current names; removed IDs retain recorded names.
`src/summaries.zig` builds owned period/total slices with borrowed identities, using
the same measured-duration attribution as Today/This week. Previous periods are
found from the instant before each calendar boundary, not fixed 24-/168-hour
subtraction. Tests cover DST, years, half-open window limits, live Monday splits,
empty periods, identity grouping, navigation, no idle redraw, resize, and live
quit-saving. Reports are recomputed on redraw and scan history per period;
large-history resource scaling remains unverified. No summary CSV export or
navigation beyond these fixed windows is included; session CSV/history formats
are unchanged.

## Explicit incomplete-tail recovery

Normal startup still rejects incomplete/corrupt history. To create a separate
recovered file, run:

```sh
./zig-out/bin/bad_timer --recover-history SOURCE DESTINATION
```

This macOS command requires interactive stdin but not Ghostty, config, or `HOME`.
It does not enter raw mode or an alternate screen. It warns that trailing bytes
may contain a real time transition, then requires exactly `yes` followed by Enter.
Anything else, EOF, or interruption before confirmation leaves files unchanged.
Arguments cannot be combined with `--config`/`--history` or other options.

Success reports retained bytes, omitted uncertain bytes, completed-session count,
and unfinished-session status. Neither file is activated or replaced. Keep the
original backup and review the result before explicitly choosing the new history
with `--history DESTINATION`. A failed command reports an error; preserve the
source and inspect the destination before retrying, especially after interruption.
Publication does not guarantee directory-metadata durability across power loss.

The command calls `src/history_recovery.zig`'s
`recover(allocator, io, dir, source_path, destination_path) !Report` API.

Call only after explicit authorization to omit the trailing bytes. The API opens
an existing source read-only, takes the same exclusive cooperative file lock as
storage, and validates the entire LF-terminated prefix using normal history replay.
It rejects malformed complete records and invalid transitions, rather than skipping
past corruption. Empty or fully LF-terminated valid logs return
`NoIncompleteTrailingRecord` without publishing anything.

The prefix is copied byte-for-byte into a private (0600), synced temporary file,
then atomically published to a new destination without overwriting files, symlinks,
or directories. The source is never edited or replaced: **keep it as the backup**.
The report gives retained/omitted byte counts, completed-session count, and any
unfinished session ID. A retained unfinished session still requires normal explicit
end-time/duration/discard recovery; no time is inferred from the missing tail.

Even syntactically valid JSON without its final LF is omitted as uncertain. If
there are no complete records, the result is an empty history. This can omit a
real transition and must never be presented as lossless repair. The original
source is needed to investigate that uncertainty. The lock protects against
cooperating writers, not external edits or path replacement. The whole source is
loaded into memory. Directory metadata is not synced, so power-loss durability of
publication is not guaranteed; temporary-file cleanup is best effort.

Tests cover every nonempty partial-stop tail (including JSON missing only LF),
completed/unfinished/empty prefixes, complete-record corruption, invalid
transitions, locking, missing sources, existing destinations, and injected partial
write/sync failures. They check exact source preservation and unpublished-file cleanup.
PTY tests also cover CLI confirmation, cancellation/EOF/Ctrl-C, argument validation,
non-interactive rejection, completed/unfinished reports, corruption, conflicts,
write failure, unchanged source content/mtime, and unchanged terminal modes.

## CSV encoding and file publishing

Press `e` outside the activity menu to export all completed sessions to the
current working directory. Reports are named `bad-timer-1.csv`, `bad-timer-2.csv`,
etc.; existing destinations are skipped, never replaced. The screen shows the
relative report path on success, or an error on failure without exiting.
Export does not stop or switch a running timer, and never changes history.
Stop/switch first to include the current session. Empty history exports only the
header. Export errors may require fixing directory permissions or freeing disk
space before pressing `e` again.

`bad_timer.csv.encode(allocator, sessions)` in `src/export.zig` returns owned CSV
bytes for completed sessions in input order; the caller frees the result. It does
not read history, include a live session, or write files. Empty input returns only
`activity_id,activity_name,start_utc,end_utc,duration_seconds` and a CRLF.

Rows use historical IDs/names, CRLF record endings, and UTC ISO-8601 timestamps
with nine fractional digits (years 0001–9999). Out-of-range timestamps reject the
whole export. Duration seconds have nine fractional digits, preserving recorded
monotonic nanoseconds even when UTC endpoints disagree or run backwards.
Text fields are always double-quoted; embedded quotes are doubled, and Unicode,
commas, CR, and LF are retained. Formula-like fields beginning with `=`, `+`, `-`,
or `@` (also after leading ASCII whitespace/control bytes), or beginning with a
tab/CR/LF, receive a leading apostrophe inside the quotes. This deliberately
changes exported text for spreadsheet safety; it does not change history.

Tests cover exact output, empty input, quoting, formula neutralization in both
text columns, historical names, pre-epoch/leap dates, timestamp limits, duration
extremes, backwards UTC, and row order. Actual spreadsheet applications have not
been tested. TUI integration remains deferred.

`bad_timer.csv.publish(allocator, io, dir, path, sessions)` encodes the supplied
completed sessions, writes and syncs a temporary file in the destination directory,
then atomically publishes it without replacing any existing file, directory, or
symlink. Reports use owner-only permissions (`0600`, subject to umask). Parent
directories must already exist. Encoding, write, sync, and publish errors propagate
to the caller; history is never modified. Tests cover published bytes, empty history,
existing destinations, partial-write/sync failures, and temporary-file cleanup.

Cleanup is best effort: a crash or cleanup failure can leave a temporary file.
Directory metadata is not synced, so successful publication does not guarantee
survival of sudden power loss. No report path or filename policy is chosen yet;
this API is not connected to the `e` key.

## In-memory history codec

`src/history.zig` supports version-1 legacy and version-2 JSON Lines events and replays them entirely
in memory. `encode` returns an allocated LF-terminated record. Each event has
required `version` and `change` fields; `change` contains exactly one `start`,
`stop`, `switch_activity`, `discard`, or version-2 `legacy_timezone` value.
Starts carry a positive, strictly increasing `session_id`, an activity ID/name
snapshot, and `start_utc_ns`; version-2 starts also require a validated IANA
`time_zone`. The saved zone belongs to that session, not the activity ID: stops,
switch completion, recovery, and restart retain it. New app writes use version 2;
older binaries reject upgraded logs. Version-1 records after an upgrade are rejected.
Stops carry the
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
preparation. Startup recovery prompts are described below. Replay currently retains the entire history in
memory; it does not stream or impose a file-size limit.

### Session timezone persistence and cutoff integration

On start/switch, an explicit configured zone wins; otherwise the system zone is
resolved again at that start, with UTC fallback. The session's identifier is
persisted and synced before the live timer commits; later config/system changes
do not change it. Identifiers, not a frozen copy of historical OS zone rules, are
stored. UTC timestamps, elapsed durations, and session CSV columns are unchanged.

At normal startup, completed/unfinished legacy sessions without a zone receive
the current resolved config/system zone **once**, via an appended version-2
`{"version":2,"change":{"legacy_timezone":"America/Los_Angeles"}}` record.
The original records are never rewritten; this is an assignment, not a recovery
of unknowable original timezone metadata. All then-unzoned sessions inherit that
name during replay. The assignment cannot be repeated or changed, and is written
under the history lock and synced before terminal setup/recovery prompts. Failure
aborts startup with an uncertainty warning; preserve the file and restart, do not
retry in the process. Thus even quitting an unfinished-session prompt can leave a
new startup assignment record, but does not resolve or add time to that session.
Empty/already-zoned histories receive no assignment write. The explicit tail
recovery command preserves bytes and does not assign zones.

Today/This week and the 7-day/4-week screens now keep shared display-zone date
labels but interpret each date's cutoffs in each session's saved zone, including
live sessions; there is no timezone grouping. Config changes affect shared labels
but never replace saved session zones. History and CSV are not changed by browsing. Tests cover legacy completed/unfinished
assignment, exact prefix preservation, owned zone names, atomic switches, restart,
config changes, malformed/version validation, and write/sync failure blocking.
Actual OS timezone changes during a running process were not manually tested.

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
An unfinished session opens a recovery screen showing its session ID, historical
activity name, and start as a readable UTC timestamp with nine fractional digits.
The screen uses the same bounded, no-wrap layout as the main screen, with controls
at the bottom and an explicit warning that no time is counted automatically.
Press `d`
to explicitly discard it without adding completed time, or `q` / Ctrl-C to exit
without changing history. Press `t` to enter an end time as `YYYY-MM-DDTHH:MM:SSZ`
(explicit UTC, whole seconds, years 0001–9999). Backspace edits; Enter validates
and shows the inferred duration; `y` confirms and saves. Escape cancels entry or
confirmation without writing. End times before the start, invalid calendar dates,
and durations exceeding the stored `u64` nanosecond range are rejected.
Recovery infers duration from UTC timestamps, not a surviving monotonic reading;
wall-clock changes during the interrupted session cannot be reconstructed. Review
that estimate before confirming.

Alternatively, press `u` to supply a duration using Go `time.ParseDuration` syntax:
`1h30m`, `2.5h`, `300ms`, or `1µs` (`us` and `μs` also work). Units are `ns`,
`us`/`µs`/`μs`, `ms`, `s`, `m`, and `h`; days, whitespace, and exponent notation
are not accepted. Fractions truncate to nanoseconds per component, as in Go.
The optional leading sign and Go's signed 64-bit nanosecond range apply, but
negative results are rejected for recovery (negative values truncating to zero
are accepted). The end is derived as the original start plus supplied duration.
Review shows the derived end as a UTC timestamp and duration as
`HH:MM:SS.nnnnnnnnn`, preserving exact nanosecond precision. `y` saves; Escape
cancels. This is an explicit estimate, not measured elapsed time.
Confirmation requires at least 60 columns × 10 rows so the review details and
warnings fit; on smaller terminals `y` is disabled until resize. Quit/cancel
remain available, and history is unchanged while resizing or reviewing. Dates
outside years 1–9999 display an explicit range warning rather than raw epoch
numbers. Entry is limited to 256 UTF-8 bytes; overflow requires Escape and re-entry.

Discard or confirmed stop is persisted and synced
before the timer screen appears; restarting then opens stopped. Both append
without rewriting original records and use the historical activity name/ID.
Loading retains
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
corrupt bytes still abort startup and must be preserved. Use the explicit
`--recover-history SOURCE DESTINATION` command described above for an incomplete
tail; normal startup never automatically repairs or replaces history.
The recovery prompt exits on append failure with the history path and an uncertainty
warning; it does not retry or claim recovery succeeded. Numeric controls use the same fail-closed policy.

Tests cover durable start/switch/stop/discard, preserved original bytes, discarded
session IDs remaining consumed, rejected transitions without file changes,
injected partial-write/sync failures, blocked retries, and restart uncertainty.
Tests also cover creation, lock release, replay across reopen, completed/unfinished
sessions, process exclusion, restrictive creation permissions, access errors,
and preservation of corrupt bytes and terminal settings. PTY checks cover recovery
cancel/interruption, ignored keys, durable discard and confirmed end-time recovery,
invalid end times, restart, and file-size-limit write failures with terminal cleanup.
Deterministic recovery tests cover calendar validation, epoch conversion, and duration bounds.
Duration compatibility fixtures are generated by Go itself; regenerate with
`go run tests/duration_oracle.go > src/duration_cases.json` (Go is not needed to build/test).
PTY tests also cover duration confirmation, Unicode units, oversized input, cancellation,
restart, and append failure.

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

When `time_zone` is omitted, the app uses the macOS system timezone, with `UTC`
as a fallback if the system identifier is unavailable or unsupported. The resolved
display zone is shown on screen and stays fixed until restart. Independently,
new session starts resolve the system zone again and persist it with the session;
explicit config zones remain fixed. Explicit null, empty, or unknown zones are rejected.
**Changed default:** omitted-zone configs now use local calendar boundaries for
daily/weekly totals; set `"time_zone": "UTC"` to retain the previous behavior.
Persisted timestamps and CSV remain UTC and existing history is not rewritten. At least one activity is required. IDs must be unique and
nonblank; names must be nonblank (blank means only ASCII spaces, tabs, CR, or LF).
Strings are preserved without trimming; IDs are case-sensitive. Malformed JSON,
missing required fields, wrong types, duplicate fields, and unknown fields are
rejected. Config order assigns numeric keys `1`–`9`; later activities are retained
in order without numeric keys in the activity menu. Reordering never changes IDs.

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
