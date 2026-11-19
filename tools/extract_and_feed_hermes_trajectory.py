#!/usr/bin/env python3
"""
tools/extract_and_feed_hermes_trajectory.py

Pulls real historical conversation sessions from Hermes/Finny SQLite state.db,
normalizes them into Headlong steps, appends them directly to a Headlong identity,
and triggers the Headlong thinker for proactive analysis. No live MCP connection needed.
"""

import sys
import os
import json
import sqlite3
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_STATE_DB = Path.home() / ".hermes" / "state.db"
BIN_TRAJ = REPO_ROOT / "bin" / "traj"


def extract_hermes_sessions(db_path: Path, limit: int = 3):
    if not db_path.exists():
        print(f"Error: Hermes state.db not found at {db_path}", file=sys.stderr)
        sys.exit(1)

    conn = sqlite3.connect(str(db_path))
    cursor = conn.cursor()

    cursor.execute("""
        SELECT id, source, datetime(started_at, 'unixepoch'), message_count 
        FROM sessions 
        WHERE message_count > 0 
        ORDER BY started_at DESC 
        LIMIT ?;
    """, (limit,))
    sessions = cursor.fetchall()

    extracted = []
    for sid, source, started_at, msg_count in sessions:
        cursor.execute("""
            SELECT role, content 
            FROM messages 
            WHERE session_id = ? 
            ORDER BY id ASC;
        """, (sid,))
        rows = cursor.fetchall()
        turns = [{"from": "human" if r == "user" else ("gpt" if r == "assistant" else r), "value": c or ""} for r, c in rows]
        extracted.append({
            "session_id": sid,
            "source": source,
            "started_at": started_at,
            "conversations": turns
        })

    conn.close()
    return extracted


def feed_to_headlong(identity: str, session: dict):
    print(f"\n--- Ingesting Hermes Session: {session['session_id']} ({session['source']}, {session['started_at']}) ---")
    identity_dir = REPO_ROOT / ".identities" / identity
    trajectories_dir = identity_dir / "trajectories"
    trajectories_dir.mkdir(parents=True, exist_ok=True)

    # Find root trajectory id
    root_traj_dir = None
    for p in trajectories_dir.iterdir():
        if p.is_dir() and (p / "trajectory.jsonl").exists():
            root_traj_dir = p
            break

    if not root_traj_dir:
        root_traj_dir = trajectories_dir / "00000001-root"
        root_traj_dir.mkdir(parents=True, exist_ok=True)
        traj_file = root_traj_dir / "trajectory.jsonl"
        with open(traj_file, "w") as f:
            f.write(json.dumps({"type": "trajectory", "step_id": "00000001-root", "ts": "2026-11-19T00:00:00Z"}) + "\n")

    env = os.environ.copy()
    env["IDENTITY_NAME"] = identity
    env["IDENTITY_DIR"] = str(identity_dir)
    env["TRAJ_DIR"] = str(trajectories_dir)
    env["TRAJ_ID"] = root_traj_dir.name
    env["MEM_DIR"] = str(identity_dir / "memories")
    env["HEADLONG_HOME"] = env.get("HEADLONG_HOME", str(Path.home() / ".headlong"))
    env["PATH"] = f"{REPO_ROOT / 'bin'}:{env.get('PATH', '')}"

    os.makedirs(env["MEM_DIR"], exist_ok=True)

    appended = 0
    for turn in session["conversations"]:
        role = turn["from"]
        val = turn["value"]

        if role == "human":
            step = {"type": "message", "from": "user", "to": identity, "content": val, "source": "hermes-chat"}
        elif role == "gpt":
            if "<tool_call>" in val:
                step = {"type": "action", "content": val, "source": "hermes-agent"}
            else:
                step = {"type": "message", "from": identity, "to": "user", "content": val, "source": "hermes-agent"}
        elif role == "tool":
            step = {"type": "observation", "content": val, "source": "hermes-tool"}
        else:
            continue

        res = subprocess.run(
            [str(BIN_TRAJ), "append"],
            input=json.dumps(step),
            text=True,
            capture_output=True,
            env=env,
            cwd=str(REPO_ROOT)
        )
        if res.returncode == 0:
            appended += 1

    print(f"Appended {appended} steps to Headlong trajectory '{root_traj_dir.name}'.")

    # Now run finance_critic step
    print("\n--- Running thinkers/finance_critic Step ---")
    critic_proc = subprocess.run(
        [str(REPO_ROOT / "thinkers" / "finance_critic" / "step")],
        env=env,
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT)
    )

    traj_file = root_traj_dir / "trajectory.jsonl"
    with open(traj_file, "r") as f:
        all_steps = [json.loads(line) for line in f if line.strip()]

    latest = all_steps[-1]
    print(f"Outcome step type: {latest.get('type')}")
    print(f"Outcome content: {latest.get('content')}")
    print(f"Source: {latest.get('source')}")


def main():
    identity = sys.argv[1] if len(sys.argv) > 1 else "finny"
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 1

    print(f"Target Headlong Identity: {identity}")
    print(f"Reading from: {DEFAULT_STATE_DB}")

    sessions = extract_hermes_sessions(DEFAULT_STATE_DB, limit=limit)
    for s in sessions:
        feed_to_headlong(identity, s)


if __name__ == "__main__":
    main()
