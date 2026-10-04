#!/usr/bin/env bash
# Failed or cancelled searches must close their pipes and stop their children.
# Python supplies a portable timeout, including on macOS without GNU timeout.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 - "$(dirname "$HERE")" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

repo = Path(sys.argv[1])


def alive(pid):
    result = subprocess.run(
        ["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True
    )
    # An adopted zombie has stopped and cannot hold an output pipe open.
    return bool(result.stdout.strip()) and not result.stdout.strip().startswith("Z")


def check(name, body, expected, cancel=None, heartbeat="0.1"):
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        (work / "bin").mkdir()
        (work / "mem").mkdir()
        (work / "mem" / "capture.md").write_text(
            "---\nsummary: capture race\ntype: fact\n---\ncapture race\n"
        )
        # Record the model, heartbeat, worker, and sleep PIDs. The sleep wrapper
        # execs the real sleep so the recorded PID remains valid.
        for tool, script in {
            "llm": 'cat >/dev/null\nprintf "%s %s\\n" "$$" "$PPID" >> "$PIDS"\n' + body,
            "sleep": 'printf "%s %s\\n" "$$" "$PPID" >> "$PIDS"\nexec /bin/sleep "$@"',
        }.items():
            path = work / "bin" / tool
            path.write_text("#!/usr/bin/env bash\n" + script + "\n")
            path.chmod(0o755)
        env = dict(os.environ, PATH=f'{work / "bin"}:{os.environ["PATH"]}',
                   MEM_DIR=str(work / "mem"), MEM_SEARCH_HEARTBEAT_S=heartbeat,
                   PIDS=str(work / "pids"), READY=str(work / "ready"))
        process = subprocess.Popen(
            [str(repo / "bin" / "mem"), "search", "capture race"],
            cwd=work, env=env, start_new_session=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

        def recorded():
            path = work / "pids"
            return {int(pid) for pid in path.read_text().split()} if path.exists() else set()

        try:
            if cancel:
                deadline = time.monotonic() + 5
                while not (work / "ready").exists():
                    assert time.monotonic() < deadline, "model never became ready"
                    time.sleep(0.02)
                # Allow the heartbeat to start its own sleep before cancellation.
                time.sleep(0.2)
                process.send_signal(cancel)
            out, err = process.communicate(timeout=5)
            assert process.returncode == expected, (process.returncode, err.decode())
            assert out == (b"matched memory\n" if expected == 0 else b""), out
            deadline = time.monotonic() + 2
            while any(alive(pid) for pid in recorded()) and time.monotonic() < deadline:
                time.sleep(0.02)
            survivors = sorted(pid for pid in recorded() if alive(pid))
            assert not survivors, f"surviving descendants: {survivors}"
            print(f"ok   {name}", flush=True)
        finally:
            # Clean up even when testing a broken implementation. The worker
            # may have its own process group, so also stop recorded descendants.
            for pid in recorded():
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate(timeout=5)


check("successful search closes pipes and reaps heartbeat", 'sleep 0.3; echo "matched memory"', 0)
check("failed model preserves exit 42 and reaps heartbeat", "sleep 0.3; exit 42", 42)
check("worker TERM preserves exit 143", 'sleep 0.3; kill -TERM "$PPID"; exit 0', 143)
for sig, code in [(signal.SIGTERM, 143), (signal.SIGINT, 130)]:
    for heartbeat in ["0.1", "0"]:
        check(f"public PID {sig.name}, heartbeat={heartbeat}",
              'sleep 30 & child=$!; : > "$READY"; wait "$child"',
              code, cancel=sig, heartbeat=heartbeat)
print("\n7 passed, 0 failed")
PY
