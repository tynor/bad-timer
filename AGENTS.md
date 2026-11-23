# bad-timer: agent context

## Purpose

A lightweight terminal UI for tracking time during the workday:
- Customizable activities.
- One-key start, stop, and switching between activities.
- CSV report export.
- Minimal CPU, memory, and disk usage.

## Status and approval gate

The first approved step adds a minimal macOS/Ghostty terminal screen, single-byte
input, resize handling, and cleanup. No timer, activity configuration, persistence,
full activity TUI, or CSV export is implemented. Real Ghostty validation is pending.
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
- `src/root.zig`: starter library functions and sample test.
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
`zig build run` was not checked. These checks cover only the starter template,
not any timer functionality. The initial nono launcher denial is resolved.
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
