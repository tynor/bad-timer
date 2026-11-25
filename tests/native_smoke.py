#!/usr/bin/env python3
"""Bridge integration: real locked storage, transitions, replay, unfinished refusal."""
import json
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
subprocess.run(["zig", "build", "native"], cwd=ROOT, check=True)
with tempfile.TemporaryDirectory(prefix="bad-timer-native-") as directory:
    base = Path(directory)
    executable = base / "bridge-test"
    subprocess.run(["clang", str(ROOT / "tests/native_bridge.c"),
                    str(ROOT / "zig-out/lib/libbad_timer_core.a"),
                    "-framework", "CoreFoundation", "-o", str(executable)], check=True)
    config = base / "config.json"
    history = base / "history.jsonl"
    config.write_text(json.dumps({"time_zone": "UTC", "activities": [
        {"id": "work", "name": "Work"}, {"id": "rest", "name": "Rest"}]}))
    # Completed current-day fixtures include a renamed ID and a removed ID.
    fixture = base / "totals.jsonl"
    records = []
    timestamp = time.time_ns()
    for session_id, (identity, seconds) in enumerate([
        ({"id": "work", "name": "Old work"}, 8),
        ({"id": "removed", "name": 'Removed "activity"'}, 5),
    ], 1):
        records.extend([
            {"version": 2, "change": {"start": {"session_id": session_id, "activity": identity,
                "start_utc_ns": timestamp, "time_zone": "UTC"}}},
            {"version": 2, "change": {"stop": {"session_id": session_id, "activity": identity,
                "end_utc_ns": timestamp, "duration_ns": seconds * 10**9}}},
        ])
    fixture.write_text("".join(json.dumps(record) + "\n" for record in records))
    original = fixture.read_bytes()
    original_mtime = fixture.stat().st_mtime_ns
    snapshot = json.loads(subprocess.check_output([
        str(executable), str(config), str(fixture), "totals"], text=True))
    assert snapshot["zone"] == "UTC"
    assert snapshot["rows"] == [
        {"name": "Work", "index": 0, "today": "00:00:08", "week": "00:00:08"},
        {"name": "Rest", "index": 1, "today": "00:00:00", "week": "00:00:00"},
        {"name": 'Removed "activity"', "index": None, "today": "00:00:05", "week": "00:00:05"},
    ], snapshot
    assert fixture.read_bytes() == original
    assert fixture.stat().st_mtime_ns == original_mtime
    subprocess.run([str(executable), str(config), str(history), "normal"], check=True)
    before = history.read_bytes()
    events = [json.loads(line) for line in before.splitlines()]
    assert len(events) == 6, events
    subprocess.run([str(executable), str(config), str(history), "unfinished"], check=True)
    assert history.read_bytes() == before
print("Native bridge checks passed")
