#!/usr/bin/env python3
"""
Test replay harness for Finny-Prime -> Headlong MCP bridge.
Sends JSON-RPC stdio calls to tools/headlong-trajectory-mcp to:
1. Initialize the MCP connection.
2. Ingest tests/fixtures/hermes_sample_trajectory.json.
3. Verify that steps are written into Headlong's trajectory.
4. Execute thinkers/finance_critic/step and verify idle vs. alert behavior.
"""

import sys
import os
import json
import subprocess
import tempfile
import shutil
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MCP_SERVER = REPO_ROOT / "tools" / "headlong-trajectory-mcp"
FIXTURE = REPO_ROOT / "tests" / "fixtures" / "hermes_sample_trajectory.json"


def run_mcp_test():
    print("=== Step 1: Initialize Headlong MCP Test Identity ===")
    test_identity = "test-finny"
    identity_dir = REPO_ROOT / ".identities" / test_identity
    traj_dir = identity_dir / "trajectories" / "00000001-root"
    traj_dir.mkdir(parents=True, exist_ok=True)
    traj_file = traj_dir / "trajectory.jsonl"
    
    # Initialize trajectory header if not present
    if not traj_file.exists():
        with open(traj_file, "w") as f:
            f.write(json.dumps({"type": "trajectory", "step_id": "00000001-root", "ts": "2026-11-19T00:00:00Z"}) + "\n")

    print(f"Test trajectory initialized at {traj_file}")

    print("=== Step 2: Start MCP Server and Ingest Hermes Trajectory ===")
    with open(FIXTURE, "r") as f:
        hermes_data = json.load(f)

    proc = subprocess.Popen(
        [str(MCP_SERVER)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        cwd=str(REPO_ROOT)
    )

    # 1. initialize
    init_req = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {"protocolVersion": "2024-11-05", "capabilities": {}}
    }
    proc.stdin.write(json.dumps(init_req) + "\n")
    proc.stdin.flush()
    init_res = json.loads(proc.stdout.readline())
    assert init_res.get("result", {}).get("serverInfo", {}).get("name") == "headlong-trajectory-mcp", f"Init failed: {init_res}"
    print("MCP Initialized successfully:", init_res["result"]["serverInfo"])

    # 2. ingest_hermes_trajectory
    ingest_req = {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/call",
        "params": {
            "name": "ingest_hermes_trajectory",
            "arguments": {
                "identity": test_identity,
                "conversations": hermes_data["conversations"],
                "model": hermes_data.get("model", ""),
                "completed": True
            }
        }
    }
    proc.stdin.write(json.dumps(ingest_req) + "\n")
    proc.stdin.flush()
    ingest_res = json.loads(proc.stdout.readline())
    content = json.loads(ingest_res["result"]["content"][0]["text"])
    assert content.get("status") == "ok", f"Ingestion failed: {content}"
    print(f"Ingested {content.get('appended_count')} turns into Headlong trajectory. Step IDs: {content.get('step_ids')}")

    proc.stdin.close()
    proc.wait()

    print("=== Step 3: Verify Steps in trajectory.jsonl ===")
    with open(traj_file, "r") as f:
        lines = [json.loads(line) for line in f if line.strip()]

    print(f"Total steps in trajectory: {len(lines)}")
    types = [step.get("type") for step in lines]
    print(f"Step types observed: {types}")
    assert "observation" in types, "Expected observation step from Hermes tool output"
    assert "action" in types, "Expected action step from Hermes tool call"
    assert "message" in types, "Expected message step from Hermes conversation"

    print("=== Step 4: Run thinkers/finance_critic Step Evaluation ===")
    env = os.environ.copy()
    mem_dir = identity_dir / "memories"
    mem_dir.mkdir(parents=True, exist_ok=True)
    env["IDENTITY_NAME"] = test_identity
    env["IDENTITY_DIR"] = str(identity_dir)
    env["TRAJ_DIR"] = str(identity_dir / "trajectories")
    env["TRAJ_ID"] = "00000001-root"
    env["MEM_DIR"] = str(mem_dir)
    env["HEADLONG_HOME"] = env.get("HEADLONG_HOME", str(Path.home() / ".headlong"))
    env["PATH"] = f"{REPO_ROOT / 'bin'}:{env.get('PATH', '')}"

    critic_proc = subprocess.run(
        [str(REPO_ROOT / "thinkers" / "finance_critic" / "step")],
        env=env,
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT)
    )
    assert critic_proc.returncode == 0, f"critic step failed: {critic_proc.stderr}"
    with open(traj_file, "r") as f:
        all_steps = [json.loads(line) for line in f if line.strip()]

    latest_step = all_steps[-1]
    print(f"Latest step appended by finance_critic: {latest_step}")
    assert latest_step.get("source") == "finance_critic", f"Expected source finance_critic, got: {latest_step}"
    
    # Check that alert observation was recorded
    assert "Acme Corp AR alert" in latest_step.get("content", ""), f"Unexpected content: {latest_step}"
    print("=== PASS: MVP Trajectory Ingestion and Autonomous Proactive Alert Succeeded! ===")

    # Cleanup test identity
    shutil.rmtree(identity_dir, ignore_errors=True)


if __name__ == "__main__":
    run_mcp_test()
