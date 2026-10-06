#!/usr/bin/env bash
# Exercise live contention and offline recovery after interrupted process trees.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$REPO" <<'PY'
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

repo = Path(sys.argv[1])
real_stat = shutil.which("stat")
assert real_stat

for stop_signal in (signal.SIGTERM, signal.SIGKILL):
    with tempfile.TemporaryDirectory(prefix="chat-index-lock-") as tmp:
        work = Path(tmp)
        trajectory_dir = work / "trajectories" / "cafe0000-0000-0000-0000-0000000000ce"
        trajectory_dir.mkdir(parents=True)
        trajectory = trajectory_dir / "trajectory.jsonl"
        index = trajectory_dir / "messages.jsonl"
        gate = work / "gate"
        gate.mkdir()
        shim = work / "shim"
        shim.mkdir()
        env = {
            "PATH": str(repo / "bin") + os.pathsep + os.environ["PATH"],
            "TRAJ_DIR": str(trajectory_dir.parent),
            "TRAJ_ID": trajectory_dir.name,
            "IDENTITY_NAME": "ada",
            "CHATRC": str(work / "chatrc"),
            "SHELLM_ENV": "local",
        }
        command = ["bash", str(repo / "bin/chat"), "history", "--with", "reader", "--json"]

        def message(step_id):
            with trajectory.open("a") as stream:
                stream.write(json.dumps({
                    "step_id": step_id, "type": "message", "from": "reader",
                    "to": "ada", "content": "hello", "ts": "2026-01-01T00:00:00Z",
                }, separators=(",", ":")) + "\n")

        def history():
            result = subprocess.run(command, env=env, cwd=work, capture_output=True,
                                    text=True, check=True, timeout=5)
            return [entry["step_id"] for entry in json.loads(result.stdout)]

        trajectory.write_text('{"type":"trajectory","step_id":"header"}\n')
        message("m1")
        assert history() == ["m1"]
        # The no-new-data return must release the lock as well.
        assert history() == ["m1"]
        message("m2")
        (shim / "stat").write_text('''#!/usr/bin/env bash
set -euo pipefail
: > "$TEST_GATE/ready"
for ((attempt=0; attempt<200; attempt++)); do
    [[ ! -f "$TEST_GATE/release" ]] || exec "$REAL_STAT" "$@"
    sleep 0.05
done
exit 1
''')
        (shim / "stat").chmod(0o755)
        worker_env = dict(env, PATH=str(shim) + os.pathsep + env["PATH"],
                          TEST_GATE=str(gate), REAL_STAT=real_stat)
        worker = subprocess.Popen(command, env=worker_env, cwd=work,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  start_new_session=True)
        try:
            deadline = time.monotonic() + 5
            while not (gate / "ready").exists():
                assert worker.poll() is None, "updater exited before the gate"
                assert time.monotonic() < deadline, "updater did not reach the gate"
                time.sleep(0.01)
            assert history() == ["m1"], "a contender stole a live updater's lock"
            os.killpg(worker.pid, stop_signal)
            worker.communicate(timeout=5)
            message("m3")
            assert history() == ["m1"], "interrupted lock must not be stolen automatically"
            before = trajectory.read_bytes()
            reset = ["bash", str(repo / "bin/chat"), "index-reset"]
            refused = subprocess.run(reset, env=env, cwd=work, capture_output=True, timeout=5)
            assert refused.returncode != 0, "reset must require the offline acknowledgement"
            assert (trajectory_dir / "messages.jsonl.lock").is_dir()
            # Model a killed writer which had appended rows but not its cursor.
            with index.open("a") as stream:
                stream.write('{"step_id":"partial-write"}\n')
            subprocess.run(reset + ["--offline"], env=env, cwd=work,
                           capture_output=True, check=True, timeout=5)
            assert trajectory.read_bytes() == before, "reset touched the source trajectory"
            for name in ("messages.jsonl", "messages.jsonl.offset", "deferrals.jsonl", "deliveries.jsonl", "messages.jsonl.lock"):
                assert not (trajectory_dir / name).exists(), name + " survived reset"
            assert history() == ["m1", "m2", "m3"], "offline reset did not restore indexing"
            rows = [json.loads(line)["step_id"] for line in index.read_text().splitlines()]
            assert rows == ["m1", "m2", "m3"], "recovery duplicated or lost indexed messages"
            assert history() == rows, "recovery left a lock behind"
            lock = trajectory_dir / "messages.jsonl.lock"
            lock.mkdir()
            (lock / "unexpected").write_text("keep")
            refused = subprocess.run(reset + ["--offline"], env=env, cwd=work,
                                     capture_output=True, timeout=5)
            assert refused.returncode != 0 and (lock / "unexpected").read_text() == "keep"
            assert index.exists(), "refusing an unknown lock changed the index"
            (lock / "unexpected").unlink()
            lock.rmdir()
            target = work / "unrelated"
            target.mkdir()
            lock.symlink_to(target, target_is_directory=True)
            refused = subprocess.run(reset + ["--offline"], env=env, cwd=work,
                                     capture_output=True, timeout=5)
            assert refused.returncode != 0 and lock.is_symlink() and index.exists()
            lock.unlink()
            # A failed reset must keep the lock and leave the trajectory alone.
            index.unlink()
            index.mkdir()
            failed = subprocess.run(reset + ["--offline"], env=env, cwd=work,
                                    capture_output=True, timeout=5)
            assert failed.returncode != 0 and lock.is_dir()
            assert trajectory.read_bytes() == before
            index.rmdir()
            for _ in range(2):
                subprocess.run(reset + ["--offline"], env=env, cwd=work,
                               capture_output=True, check=True, timeout=5)
            assert history() == rows, "reset is not idempotent"
            print("ok live contention, guarded reset, and offline recovery after " + stop_signal.name)
        finally:
            try:
                os.killpg(worker.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            worker.communicate(timeout=5)
PY
