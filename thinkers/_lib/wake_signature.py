#!/usr/bin/env python3
"""Conservative wake fingerprint. Failure must mean a full turn, never a skip."""
import hashlib
import json
import pathlib
import sys

h = hashlib.sha256()
def add(value):
    h.update(len(value).to_bytes(8, "big"))
    h.update(value)

# Bounded raw tail supplied by the caller. Ignore only execution scaffolding
# and idle/final summaries; durable work and delivery changes invalidate.
ignored = {"idle", "final", "monolith-wake", "shell", "shell-output",
           "prompt", "response", "usage", "shellm-run", "run-summary", "reasoning"}
last = None
for line in sys.stdin:
    row = json.loads(line)
    if row.get("type") not in ignored:
        last = row
add(json.dumps(last, sort_keys=True).encode())
for value in sys.argv[1:4]:  # runtime, schedule windows (not clock), config
    add(value.encode())
for name in sys.argv[4:]:
    root = pathlib.Path(name)
    add(str(root).encode())
    if not root.exists():
        add(b"absent")
        continue
    files = sorted(root.rglob("*.md")) if root.is_dir() else [root]
    for path in files:
        add(str(path).encode())
        add(path.read_bytes())
print(h.hexdigest())
