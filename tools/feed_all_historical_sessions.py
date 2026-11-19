#!/usr/bin/env python3
"""
tools/feed_all_historical_sessions.py

Iterates through historical sessions in ~/.hermes/state.db (or an exported JSON file),
ingests them session-by-session into Headlong, and triggers thinkers/finance_critic
after each session so every single historical interaction is inspected sequentially.
"""

import sys
import os
import time
import json
import sqlite3
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_STATE_DB = Path.home() / ".hermes" / "state.db"
BIN_TRAJ = REPO_ROOT / "bin" / "traj"


def get_sessions_from_db(db_path: Path, limit: int = 50):
    if not db_path.exists():
        print(f"Error: Database {db_path} not found.", file=sys.stderr)
        return []

    conn = sqlite3.connect(str(db_path))
    cursor = conn.cursor()

    cursor.execute("""
        SELECT id, source, datetime(started_at, 'unixepoch'), message_count 
        FROM sessions 
        WHERE message_count > 1 
        ORDER BY started_at ASC 
        LIMIT ?;
    """, (limit,))
    sessions = cursor.fetchall()

    result = []
    for sid, source, started_at, msg_count in sessions:
        cursor.execute("""
            SELECT role, content 
            FROM messages 
            WHERE session_id = ? 
            ORDER BY id ASC;
        """, (sid,))
        rows = cursor.fetchall()
        turns = [{"from": "human" if r == "user" else ("gpt" if r == "assistant" else r), "value": c or ""} for r, c in rows]
        result.append({
            "session_id": sid,
            "source": source,
            "started_at": started_at,
            "conversations": turns
        })

    conn.close()
    return result


def feed_session(identity: str, session: dict, step_critic: bool = True):
    sid = session["session_id"]
    source = session.get("source", "hermes")
    started_at = session.get("started_at", "")
    turns = session.get("conversations", [])

    print(f"\n=======================================================")
    print(f"▶ Feeding Session: {sid} ({source}, {started_at}) — {len(turns)} turns")
    print(f"=======================================================")

    identity_dir = REPO_ROOT / ".identities" / identity
    trajectories_dir = identity_dir / "trajectories"
    root_traj_dir = trajectories_dir / "00000001-root"

    env = os.environ.copy()
    env["IDENTITY_NAME"] = identity
    env["IDENTITY_DIR"] = str(identity_dir)
    env["TRAJ_DIR"] = str(trajectories_dir)
    env["TRAJ_ID"] = root_traj_dir.name
    env["MEM_DIR"] = str(identity_dir / "memories")
    env["HEADLONG_HOME"] = env.get("HEADLONG_HOME", str(Path.home() / ".headlong"))
    env["PATH"] = f"{REPO_ROOT / 'bin'}:{env.get('PATH', '')}"

    appended = 0
    for turn in turns:
        role = turn.get("from")
        val = turn.get("value", "")

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

    print(f"✓ Ingested {appended} steps into trajectory.")

    if step_critic:
        print("🧠 Running finance_critic step...")
        critic_proc = subprocess.run(
            [str(REPO_ROOT / "thinkers" / "finance_critic" / "step")],
            env=env,
            capture_output=True,
            text=True,
            cwd=str(REPO_ROOT)
        )
        # Read last step to show outcome
        traj_file = root_traj_dir / "trajectory.jsonl"
        with open(traj_file, "r") as f:
            last_line = [l for l in f if l.strip()][-1]
        last_step = json.loads(last_line)
        print(f"👉 Outcome [{last_step.get('type')}]: {last_step.get('content')[:140]}...")


def main():
    identity = sys.argv[1] if len(sys.argv) > 1 else "finny"
    input_source = sys.argv[2] if len(sys.argv) > 2 else "db"
    limit = int(sys.argv[3]) if len(sys.argv) > 3 else 10

    if input_source.endswith(".json"):
        print(f"Loading sessions from JSON file: {input_source}")
        with open(input_source, "r") as f:
            data = json.load(f)
        sessions = data if isinstance(data, list) else [data]
    else:
        print(f"Loading sessions from SQLite: {DEFAULT_STATE_DB} (limit={limit})")
        sessions = get_sessions_from_db(DEFAULT_STATE_DB, limit=limit)

    print(f"Found {len(sessions)} session(s) to process.")
    for idx, s in enumerate(sessions, 1):
        print(f"\n[{idx}/{len(sessions)}]")
        feed_session(identity, s, step_critic=True)
        time.sleep(1) # brief pause between wakes


if __name__ == "__main__":
    main()
