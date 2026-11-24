#!/usr/bin/env python3
"""Bridge integration: real locked storage, transitions, replay, unfinished refusal."""
import json
from pathlib import Path
import subprocess
import tempfile

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
    subprocess.run([str(executable), str(config), str(history), "normal"], check=True)
    before = history.read_bytes()
    events = [json.loads(line) for line in before.splitlines()]
    assert len(events) == 6, events
    subprocess.run([str(executable), str(config), str(history), "unfinished"], check=True)
    assert history.read_bytes() == before
print("Native bridge checks passed")
