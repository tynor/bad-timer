# bad-timer — approved project plan

**Status: approved, including all defaults in section 5.** This describes agreed
requirements, not existing features. Each implementation step still requires
separate approval as described in section 3.

## 1. MVP

A single local Zig executable that opens a small keyboard-driven timer UI. Configure
activities once, select one by numeric key or activity menu to track it, and
export recorded sessions as CSV. No account, network, daemon, or background service.

### Proposed interaction

- Each activity has a stable ID and display name. Config order assigns keys `1`–`9`
  to the first nine activities; there are no configurable per-activity shortcuts.
- Press `a` to open an activity menu listing all activities in config order,
  including those beyond nine. Use Up/Down and Enter to select, Escape to cancel.
- Selecting an activity by numeric key or menu starts it while stopped, stops it
  if already running, or ends the old session and starts the selected one at the
  same instant, with no overlap. Opening/canceling the menu does not change timing.
- Reserve `q` for clean quit and `e` for exporting a report outside the menu.
- Show activities and assigned keys, the active activity, elapsed time, today's totals,
  and a short status/help line. Do not rely on color alone.
- Quitting stops and saves the running session. Restarting opens stopped; time while
  the app is closed is not implicitly counted.

### Customization and reports

- Edit a small JSON config file to add, rename, remove, or reorder activities and
  set a display time zone; restart to apply. Reordering changes numeric keys, not
  historical identity. No in-app configuration editor in the MVP.
- Propose an IANA time-zone name (for example, `America/Los_Angeles`), defaulting
  to `UTC` when omitted. Reject unknown zones. Render session times and compute
  today's totals/day boundaries in that zone, including daylight-saving changes;
  show the configured zone in the UI. Stored timestamps and CSV remain UTC.
- Keep stable IDs and record activity names with sessions so later config edits
  cannot relabel or delete historical records.
- Export one CSV row per completed session, with header:
  `activity_id,activity_name,start_utc,end_utc,duration_seconds`.
- Use UTC ISO-8601 timestamps and numeric elapsed seconds. Quote commas, quotes,
  and newlines correctly; neutralize spreadsheet-formula text fields for safe opening.
- Export all recorded sessions initially. Stop/switch before exporting to include
  a currently running session. Never overwrite an existing report silently.

## 2. Small technical approach

### Platform and terminal

- Retain Zig; verify the declared `0.17.1` toolchain before coding against its APIs.
- Target macOS only for the MVP, with Ghostty as the supported terminal. Other
  operating systems and terminals are not initial compatibility targets.
- Target Ghostty's terminal capabilities; validate the input, rendering, resize,
  and cleanup behavior there. No cross-terminal compatibility layer is required.
- First validate raw keyboard input, timed waiting, resize handling, and terminal
  cleanup in a tiny vertical slice. Prefer standard-library/OS terminal APIs;
  propose a dependency only if they cannot reasonably cover the supported targets.
- Keep a simple event loop: wait for input or the next displayed second, redraw
  only when needed, and write storage only on state changes.

### Time and data safety

- Use a monotonic clock for elapsed time and wall-clock UTC for reporting; do not
  derive durations by subtracting wall-clock timestamps. Explain discrepancies
  caused by system clock changes rather than silently changing tracked duration.
- Propose counting suspend time as elapsed time. Verify clock behavior on macOS;
  this policy requires explicit testing, not an assumption.
- Resolve configured IANA zones using macOS time-zone facilities or system zone
  data; validate the Zig/macOS integration in a small step before committing to an
  approach. Keep elapsed durations independent of zone and daylight-saving changes.
- Use separate local config and data files in platform-appropriate user directories;
  document exact locations before implementation. No database for the MVP.
- Propose an append-only JSON Lines event log: start/stop events include session
  and activity identity; a switch records both changes in one event. Replay it
  to recover completed sessions and an unfinished session after a crash.
- Persist and flush transitions before acknowledging them. On failure, preserve
  the previous logical state and show an actionable error. Prevent concurrent
  writers with a process-lifetime lock.
- On an unclean exit, never silently count the whole gap. Ask the user to discard
  the unfinished session or supply its end time. Preserve the original log.
- Detect incomplete trailing writes and corrupt records; do not silently truncate
  or skip data. Recovery must preserve a backup and make any uncertainty explicit.
- Export through a temporary file and publish without replacing an existing file.

Keep modules small and driven by actual boundaries: timer state, storage/config,
terminal UI, and export. No generic framework or public library API is needed.

## 3. Milestones and acceptance checks

Milestones below group scope, not permission to implement them all at once.
Before each implementation step, propose a small PR-sized scope and acceptance
checks for approval. Implement only that approved step, report its diff and
verification results, then stop for review. Do not start the next step until the
user explicitly approves proceeding; plan approval is not blanket implementation
approval. Split milestones into smaller steps wherever needed for easy review.

### A. Validate foundation

- Confirm toolchain and baseline build/tests; remove starter demos as replaced.
- Prove single-key input, resize, clean exit, Ctrl-C cleanup, and unsupported-terminal errors.
- Document supported terminals/platforms and required build/run commands.

**Done when:** a minimal screen reliably restores the terminal after normal exit,
handled interruption, and recoverable errors in Ghostty on macOS.

### B. Activity configuration and timer state

- Parse and validate config: empty/duplicate IDs, blank names, invalid time zones,
  and malformed JSON. Derive numeric keys from activity order, including configs
  with fewer than nine or more than nine activities.
- Implement start, stop, switch, elapsed time, and totals with injected test clocks.
- Validate configured-zone conversion and day boundaries on macOS.

**Done when:** deterministic tests prove one active timer, same-key stop, gap-free
switching, wall-clock-change behavior, and correct totals at configured-zone day
boundaries, including daylight-saving transitions and sessions spanning midnight.

### C. Durable local history

- Implement event persistence, replay, locking, and unfinished-session recovery.
- Exercise write failures, partial writes, corrupt input, restart, and activity renames/removal.

**Done when:** completed sessions survive restart; concurrent writers are rejected;
failed writes do not claim a successful transition; crash recovery never invents time.

### D. Complete TUI and CSV export

- Connect numeric keys, the `a` activity menu, status/help, active duration, totals,
  the configured display time zone, and config errors.
- Test numeric-key assignment after reorder, selection beyond nine, menu scrolling
  and cancellation, and identical start/stop/switch behavior through either path.
- Implement export and test round trips with commas, quotes, Unicode, multiline
  names, formula-like names, empty history, and existing output files.
- Test small terminals, resize, non-TTY startup, quit while running, and export failure.

**Done when:** a user can configure activities, track a work session using single
keys, restart without losing history, and open a correct CSV report.

### E. Resource and release check

- Run build, tests, formatting, and a manual Ghostty smoke test on macOS.
- Measure a ReleaseSmall build's idle CPU, resident memory, binary size, and history
  growth over a short representative session; report machine and measurement method.
- Provisional targets for review: below 1% of one CPU core while idle and below
  20 MiB resident memory. No periodic disk writes while idle. Revise targets only
  with measurements and user approval.
- Add a short README covering installation, configuration, keys, storage/recovery,
  export schema, and known limits.

**Done when:** measured results and outstanding limitations are documented, with no
claims of verification on platforms that were not tested.

## 4. Explicitly out of scope

Cloud sync, billing/invoicing, projects/tags, Pomodoro alarms, automatic idle
tracking, background tracking after exit, live config reload, in-app history
editing, date-filtered/aggregate exports, Linux, Windows, and support guarantees
for terminals other than Ghostty.
No dependencies or implementation files are added during this planning step.

## 5. Approval decisions

User feedback establishes these constraints:

1. **Platform/terminal:** macOS initially, targeting Ghostty; retain Zig.
2. **Activity selection:** config positions 1–9 map to keys `1`–`9`; `a` opens
   a menu that also reaches all remaining activities.
3. **Display time zone:** configurable, including zone-aware daily totals.
4. **Review process:** one approved, reviewable implementation step at a time;
   stop for explicit approval before proceeding to the next step.

Approved defaults:

1. **Customization:** JSON config edited outside the app; IANA display zone,
   default `UTC`; menu navigation with Up/Down, Enter, and Escape.
2. **Controls:** selecting the running activity stops it; another switches;
   `q` quits and `e` exports outside the menu.
3. **Time policy:** suspend counts; clean exit stops; crash recovery asks rather than guesses.
4. **Reporting:** session-level CSV with UTC timestamps; UI uses the configured
   zone; no date filters yet.
5. **Resource budget:** provisional idle CPU <1% of one core and RSS <20 MiB.

Next, propose the first small implementation step for approval and
surface platform/API problems before broadening scope. Any delegated task must use `gpt-6-luna` and have narrow
file ownership and explicit acceptance checks (see `AGENTS.md`).

## 6. Approved extension: current-week totals

The user approved a This week column beside Today, for a fixed Monday–Sunday
calendar week in the configured display zone. Include completed and live measured
time by stable activity ID, including removed activities. Reuse daily attribution
rules and HH:MM:SS display; calculate real calendar boundaries across DST rather
than assuming 168 hours. Hide the week column on narrow screens while preserving
controls and menu access. Refresh on transitions, live seconds, and local-day/week
rollover without introducing idle redraws or periodic writes.

Acceptance: deterministic tests for Monday boundaries, Sunday, year rollover,
DST, zone differences, renames/removal, live sessions, rounding, and clock jumps;
PTY checks for weekly display, restart, live updates, and small-screen resizing.
History format and session-level CSV exports are unchanged. No prior-week
navigation, date filters, aggregate CSV export, or week-start configuration is
included. This extends on-screen totals only; the other exclusions still apply.
