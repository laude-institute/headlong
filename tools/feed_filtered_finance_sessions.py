#!/usr/bin/env python3
"""
tools/feed_filtered_finance_sessions.py

Filters and feeds ONLY sessions containing finance, accounting, or ERP keywords:
- NetSuite, SuiteQL, AR/AP, invoice, vendor, accrual, ledger, receipts
Skips all general tech, devops, frontend, or coding questions.
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

FINANCE_KEYWORDS = [
    "netsuite", "suiteql", "receivable", "payable", "invoice", "vendor",
    "accrual", "ledger", "receipt", "mtpl", "gl account", "reconcil",
    "custinvc", "custpymt", "unapplied", "balance", "dso"
]

def get_finance_sessions(db_path: Path):
    conn = sqlite3.connect(str(db_path))
    cursor = conn.cursor()

    # Query sessions having finance keywords in their messages
    query = """
        SELECT DISTINCT s.id, s.source, datetime(s.started_at, 'unixepoch'), s.message_count
        FROM sessions s
        JOIN messages m ON m.session_id = s.id
        WHERE s.message_count > 1
        ORDER BY s.started_at DESC;
    """
    cursor.execute(query)
    all_sessions = cursor.fetchall()

    filtered = []
    for sid, source, started_at, count in all_sessions:
        cursor.execute("SELECT role, content FROM messages WHERE session_id = ? ORDER BY id ASC;", (sid,))
        rows = cursor.fetchall()
        full_text = " ".join([c or "" for _, c in rows]).lower()

        # Check if any finance keyword matches
        if any(kw in full_text for kw in FINANCE_KEYWORDS):
            # Exclude obvious non-finance code commits or devops discussions
            if "oidc provider" in full_text or "docker" in full_text and "invoice" not in full_text:
                continue
            turns = [{"from": "human" if r == "user" else ("gpt" if r == "assistant" else r), "value": c or ""} for r, c in rows]
            filtered.append({
                "session_id": sid,
                "source": source,
                "started_at": started_at,
                "conversations": turns
            })

    conn.close()
    return filtered


def feed_session(identity: str, session: dict):
    sid = session["session_id"]
    source = session.get("source", "hermes")
    started_at = session.get("started_at", "")
    turns = session.get("conversations", [])

    print(f"\n=======================================================")
    print(f"📊 Processing Finance Session: {sid} ({source}, {started_at})")
    print(f"Turns: {len(turns)}")
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

    print("🧠 Running finance_critic reasoning step...")
    critic_proc = subprocess.run(
        [str(REPO_ROOT / "thinkers" / "finance_critic" / "step")],
        env=env,
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT)
    )

    traj_file = root_traj_dir / "trajectory.jsonl"
    with open(traj_file, "r") as f:
        last_line = [l for l in f if l.strip()][-1]
    last_step = json.loads(last_line)
    print(f"👉 Thinker Outcome [{last_step.get('type')}]:\n{last_step.get('content')}")


def main():
    identity = "finny"
    print(f"Filtering ONLY Finance/NetSuite/ERP sessions from: {DEFAULT_STATE_DB}")
    sessions = get_finance_sessions(DEFAULT_STATE_DB)
    print(f"Found {len(sessions)} pure finance/ERP session(s).")

    for idx, s in enumerate(sessions, 1):
        print(f"\n[{idx}/{len(sessions)}]")
        feed_session(identity, s)
        time.sleep(1)


if __name__ == "__main__":
    main()
