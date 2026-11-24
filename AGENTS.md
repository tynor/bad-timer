# bad-timer: agent context

## Purpose

A lightweight terminal UI for tracking time during the workday:
- Customizable activities.
- One-key start, stop, and switching between activities.
- CSV report export.
- Minimal CPU, memory, and disk usage.

## Status and approval gate

Implemented: a minimal macOS/Ghostty terminal screen, single-byte input, resize
handling, and cleanup; an isolated in-memory timer state module with injected
clock readings and deterministic tests; an isolated CoreFoundation time-zone helper
with IANA validation, local dates, and UTC calendar-day boundaries; an isolated
in-memory JSON activity-config parser with validation and ordered numeric keys.
Config is loaded and validated from `$HOME/Library/Application Support/bad-timer/config.json`
(or `--config PATH`) before terminal setup.
An isolated macOS clock adapter now returns timer readings using suspend-inclusive
`CLOCK_MONOTONIC_RAW` and UTC `CLOCK_REALTIME`; it now supplies live TUI readings.
An isolated versioned in-memory JSON Lines history codec/replayer now validates
start/stop/switch transitions and retains completed and unfinished sessions.
Startup now opens/creates and exclusively locks a history file, replaying it before
terminal setup. The default is `$HOME/Library/Application Support/bad-timer/history.jsonl`;
`--history PATH` overrides it. Parent directories must exist. An isolated
`Store.append` API now validates, writes and syncs start/stop/switch transitions
before committing logical state; write/sync failures block further appends until
restart and preserve uncertain disk bytes. History also supports an explicit
session-ID-matched discard event through `Store.append`: it clears an unfinished
session without adding completed time, rewriting records, or permitting ID reuse.
Startup now prompts for an unfinished session: `d` durably discards it without
adding time; `q` or interruption exits without changing history. Append failures
exit with an uncertainty warning. Older binaries reject logs containing discard events.
Startup recovery also accepts a strict whole-second UTC end time, shows its
wall-clock-inferred duration, and requires confirmation before durably appending a
stop using the historical activity identity. Invalid/before-start/out-of-range
inputs and cancellation leave history unchanged. Recovery also accepts Go
`time.ParseDuration` syntax through `u`, rejecting negative results and requiring
confirmation of duration and derived UTC end before saving. Go-generated fixtures
verify parsing compatibility; input is limited to 256 UTF-8 bytes.
Numeric keys now start/stop/switch activities, persisting and syncing before
committing live timer state. The screen shows assigned keys, active activity,
and elapsed seconds; clean quit and handled termination stop/save a live session.
Save failures exit with uncertainty; terminal errors leave explicit recovery for
restart. PTY tests cover controls, atomic switch, clean-exit saving, restart,
and append failure. An `a` activity menu now lists all configured activities with
Up/Down navigation, scrolling, Enter selection through the same durable transition
path, and Escape cancellation. PTY checks cover selection beyond nine, fragmented
arrow input, resize/scrolling, cancellation, and menu start/stop/switch. The menu
now shares the main screen's explicit-row layout, with separate selection (`>`)
and `[running]` labels, actual numeric shortcuts (`-` beyond nine), a position /
hidden-row-count header, and bottom navigation help. At one/two rows the selected
item includes its position; one-row terminals prioritize selection over help.
PTY tests also cover running versus selected state, scroll counts, shortcut display,
long/control-containing names, and one-/two-row resize without changing history.
An isolated CSV encoder now exports completed sessions with exact
nanosecond timestamps/durations, CSV text escaping, and spreadsheet-formula
neutralization. Its `publish` API writes and syncs a private temporary file, then
atomically publishes without replacing existing destinations. Tests cover write,
sync, and publish failures and cleanup. Cleanup is best effort; directory metadata
is not synced. Outside the activity menu, `e` now exports all completed sessions
through that publisher to numbered `bad-timer-N.csv` files in the current directory,
skipping existing destinations. Success/path or nonfatal failure appears on screen;
export leaves running timers and history unchanged. PTY tests cover empty history,
completed/live sessions, repeated exports, existing destinations, and write failure.
An isolated daily-totals calculator now groups completed/live measured durations by
stable ID for a configured-zone day, including removed activities. Positive UTC
spans split proportionally with cumulative nanosecond rounding; zero/backward
spans belong to the start date. Deterministic tests cover midnight, DST, renames,
live sessions, and clock jumps. The TUI now shows today's per-activity totals and
configured zone, including live time and removed activities. It refreshes on live
seconds, transitions, and configured-zone day changes, without idle redraws.
The cleaned-up main screen removes debug dimensions/key bytes/readiness text,
formats elapsed/totals as HH:MM:SS, and combines shortcuts, totals, and activity
names in one list with a color-independent running marker. Current config names
are used for configured IDs; removed IDs keep recorded names. Controls/status
have reserved bottom rows; small screens simplify headers/help and safely clip
with an enlargement hint. The activity menu still reaches every configured activity.
PTY tests cover live updates, restart/renames, removed activities, zone attribution,
footer/status placement, and resize down to a one-row screen.
An isolated `history_recovery.recover` API now locks an existing source, validates
all LF-terminated records, and publishes their exact prefix to a new no-overwrite
file, reporting omitted tail bytes and retained completed/unfinished sessions.
The source stays untouched as the backup. Complete-record corruption is rejected;
even valid JSON missing LF is uncertain and omitted only with explicit caller
authorization. Tests cover partial tails, preservation, lock/publication conflicts,
and write/sync failures. An explicit `--recover-history SOURCE DESTINATION` command
now exposes this API before config/TUI setup, requiring interactive stdin and an
exact `yes` line after an uncertainty warning. It reports retained/omitted bytes
and unfinished status without activating either file. PTY tests cover confirmation,
cancellation/EOF/Ctrl-C, argument validation, corruption/conflicts/write failure,
and source/terminal preservation. Normal startup still never auto-repairs history.
A repeatable `tests/resource_check.py` now checks ReleaseSmall binary size,
short-session history growth, and unchanged history content/mtime during stopped
and running no-input windows. CPU/RSS checks were skipped at user request after
sandbox denial of `ps`; their provisional targets remain unverified. Measurements
and method are in README.md. Real Ghostty and macOS suspend-clock validation are pending.
Read `PLAN.md` for the approved MVP and defaults. Plan approval is not blanket
implementation approval: propose each small implementation step and its acceptance
checks, obtain explicit approval, implement only that step, then stop for review.
The approved requirements are not existing behavior.

## Repository map

- `build.zig`: builds the `bad_timer` executable and module; run/test steps.
- `build.zig.zon`: package metadata; declares minimum Zig `0.17.1`; no dependencies.
- `src/main.zig`: minimal terminal executable, recovery prompt, and signal/termios cleanup.
- `src/recovery.zig`: strict UTC timestamp and Go-style duration recovery parsing/tests.
- `src/duration_cases.json`, `tests/duration_oracle.go`: Go-generated duration compatibility fixtures.
- `src/terminal.h`: system headers for build-time Zig C translation.
- `tests/terminal_smoke.py`: macOS PTY integration checks.
- `tests/resource_check.py`: macOS PTY size/history checks; no CPU/RSS inspection.
- `README.md`: foundation usage, verification, and known limits.
- `src/root.zig`: in-memory timer state, borrowed activity identity, and deterministic tests.
- `src/totals.zig`: isolated configured-zone daily attribution, stable-ID grouping, and tests.
- `src/time_zone.zig`, `src/time_zone.h`: macOS CoreFoundation zone/calendar helpers and tests.
- `src/clock.zig`, `src/clock.h`: macOS monotonic/UTC clock acquisition and tests.
- `src/config.zig`: owned JSON config parsing/loading, validation, numeric keys, and tests.
- `src/history.zig`: owned in-memory event encoding/replay, strict validation, and tests.
- `src/history_recovery.zig`: isolated incomplete-tail recovery to a separate file, reports, and failure tests.
- `src/export.zig`: CSV encoding, escaping, formula safety, atomic no-overwrite file publishing, and tests.
- `src/storage.zig`: history-file creation, lifetime locking, replay, durable append, and tests.
- `PLAN.md`: approved scope, behavior, milestones, and acceptance checks.

Preserve the package fingerprint in `build.zig.zon`. Do not edit generated
`.zig-cache/` or `zig-out/` contents.

## Commands

Run from the repository root:

```sh
zig version
zig build
zig build run
zig build test
zig fmt --check build.zig src
zig build -Doptimize=ReleaseSmall
python3 tests/terminal_smoke.py
# After the ReleaseSmall build:
python3 tests/resource_check.py
```

Baseline verified with Zig `0.17.1`: `zig build`, `zig build test`,
`zig fmt --check build.zig src`, and `zig build -Doptimize=ReleaseSmall` all passed.
`zig build run` was not checked. The same checks also pass with the isolated timer
state module. Clock-adapter tests also cover real clock acquisition; real suspend
behavior remains unverified. The initial nono launcher denial is resolved.
Do not work around future sandbox restrictions; diagnose and request an explicit grant.

## Implementation principles

- Keep Zig and the existing build structure unless an approved requirement needs a change.
- Prefer the standard library; justify any new dependency against the small TUI's needs.
- Implement only the approved MVP. No daemon, network service, plugin system, or GUI.
- Keep timing/state logic independent of terminal rendering so it can be tested.
- At most one activity runs at a time. Never silently lose or rewrite time records.
- Validate config and persisted input. Surface write failures before claiming success.
- Restore terminal state on exit and supported interruption paths.
- Avoid busy polling, per-frame disk writes, and unnecessary redraws.
- Test nontrivial behavior, especially transitions, persistence failures, and CSV escaping.
- Keep edits focused; update affected tests and docs. State what was not verified.

## Delegation

All sub-agents must use **`gpt-6-luna`**. If unavailable, report that rather than
silently substituting another model; work directly if appropriate.
Give each sub-agent one bounded task with explicit file paths, relevant context,
constraints, and a concrete completion check. Avoid vague architecture assignments
or overlapping write ownership. The parent agent reviews and integrates results.
Delegation is optional, not a reason to split a small task unnecessarily.
