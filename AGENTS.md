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
(or `--config PATH`) before terminal setup; activity controls and timer state remain disconnected.
An isolated macOS clock adapter now returns timer readings using suspend-inclusive
`CLOCK_MONOTONIC_RAW` and UTC `CLOCK_REALTIME`; it is not connected to the TUI.
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
This remains an API only; older binaries reject logs containing discard events.
TUI transition wiring, recovery prompts,
full activity TUI, and CSV export are not implemented. Real Ghostty and macOS suspend-clock validation are pending.
Read `PLAN.md` for the approved MVP and defaults. Plan approval is not blanket
implementation approval: propose each small implementation step and its acceptance
checks, obtain explicit approval, implement only that step, then stop for review.
The approved requirements are not existing behavior.

## Repository map

- `build.zig`: builds the `bad_timer` executable and module; run/test steps.
- `build.zig.zon`: package metadata; declares minimum Zig `0.17.1`; no dependencies.
- `src/main.zig`: minimal terminal executable and signal/termios cleanup.
- `src/terminal.h`: system headers for build-time Zig C translation.
- `tests/terminal_smoke.py`: macOS PTY integration checks.
- `README.md`: foundation usage, verification, and known limits.
- `src/root.zig`: in-memory timer state, borrowed activity identity, and deterministic tests.
- `src/time_zone.zig`, `src/time_zone.h`: macOS CoreFoundation zone/calendar helpers and tests.
- `src/clock.zig`, `src/clock.h`: macOS monotonic/UTC clock acquisition and tests.
- `src/config.zig`: owned JSON config parsing/loading, validation, numeric keys, and tests.
- `src/history.zig`: owned in-memory event encoding/replay, strict validation, and tests.
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
