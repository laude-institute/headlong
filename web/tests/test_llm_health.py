"""LLM health signal extraction + endpoints (probe CLI stubbed)."""

import json
import stat
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from headlong_web import control, llm_health
from headlong_web.server import create_app

ROOT_TRAJ = "eaeaeaea-9999-4999-8999-999999999999"


def _ts(minutes_ago: float) -> str:
    return (
        datetime.now(tz=timezone.utc) - timedelta(minutes=minutes_ago)
    ).strftime("%Y-%m-%dT%H:%M:%S+0000")


def _mk_identity(tmp_path: Path, steps: list[dict]) -> Path:
    identity = tmp_path / ".identities" / "healthy"
    identity.mkdir(parents=True)
    (identity / "info.txt").write_text(
        f"name=healthy\ncreated=x\nroot_trajectory={ROOT_TRAJ}\n"
    )
    traj = identity / "trajectories" / "eaeaeaea-root"
    traj.mkdir(parents=True)
    all_steps = [{"type": "trajectory", "step_id": ROOT_TRAJ, "ts": _ts(600)}] + steps
    (traj / "trajectory.jsonl").write_text(
        "".join(json.dumps(s) + "\n" for s in all_steps)
    )
    return tmp_path


def _thoughts(count: int, newest_minutes_ago: float, gap_s: float) -> list[dict]:
    steps = []
    for i in range(count):
        age = newest_minutes_ago + (count - 1 - i) * gap_s / 60
        steps.append(
            {"type": "thought", "source": "inner_monologue",
             "step_id": f"t{i:04d}", "content": f"idea {i}", "ts": _ts(age)}
        )
    return steps


@pytest.fixture(autouse=True)
def _fresh_cache():
    llm_health._cache.update(ts=0.0, root=None, payload=None)


def test_ok_when_no_failures(tmp_path: Path):
    root = _mk_identity(tmp_path, _thoughts(40, 1, 12))
    body = llm_health.llm_health(root)
    assert body["status"] == "ok"
    assert body["failures_1h"] == 0
    ident = body["identities"][0]
    assert ident["cadence"] is None or ident["cadence"]["recent_median_s"] > 0


def test_degraded_on_recent_failure(tmp_path: Path):
    steps = _thoughts(40, 5, 12)
    steps.append(
        {"type": "thought", "source": "inner_monologue", "step_id": "ph1",
         "content": "(inner monologue received an empty response from the LLM; continuing)",
         "ts": _ts(30)}
    )
    body = llm_health.llm_health(_mk_identity(tmp_path, steps))
    assert body["status"] == "degraded"
    assert body["failures_1h"] == 1
    assert "empty response" in body["identities"][0]["last_failure"]["content"]


def test_erroring_on_burst(tmp_path: Path):
    steps = _thoughts(40, 20, 12)
    for i in range(3):
        steps.append(
            {"type": "observation", "source": "actor", "step_id": f"f{i}",
             "content": "action failed: the run aborted before producing a result",
             "ts": _ts(5 + i)}
        )
    body = llm_health.llm_health(_mk_identity(tmp_path, steps))
    assert body["status"] == "erroring"
    assert body["failures_15m"] == 3


def test_old_failures_ignored(tmp_path: Path):
    steps = _thoughts(40, 5, 12)
    steps.insert(
        0,
        {"type": "observation", "source": "actor", "step_id": "old",
         "content": "action failed: ancient history", "ts": _ts(240)},
    )
    body = llm_health.llm_health(_mk_identity(tmp_path, steps))
    assert body["status"] == "ok"
    assert body["failures_1h"] == 0


def test_unknown_without_activity(tmp_path: Path):
    (tmp_path / ".identities").mkdir()
    body = llm_health.llm_health(tmp_path)
    assert body["status"] == "unknown"
    assert body["identities"] == []


def test_health_endpoint_and_probe(tmp_path: Path, monkeypatch):
    root = _mk_identity(tmp_path, _thoughts(20, 2, 10))
    (root / ".env").write_text("SHELLM_MODEL=test/model-1\n")

    stub = tmp_path / "stub-bin"
    stub.mkdir()
    script = stub / "llm"
    script.write_text(
        "#!/usr/bin/env bash\n"
        f'echo "ARGS=$* RETRIES=$LLM_RETRIES" >> {stub}/calls.txt\n'
        'printf \'{"choices":[{"message":{"content":"pong"}}],"provider":"StubbedAI"}\'\n'
    )
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setattr(control, "BIN_DIR", stub)

    client = TestClient(create_app(root))
    body = client.get("/api/llm-health").json()
    assert body["status"] == "ok"

    probe = client.post("/api/llm-health/probe")
    assert probe.status_code == 200, probe.text
    result = probe.json()
    assert result["ok"] is True
    assert result["provider"] == "StubbedAI"
    assert result["model"] == "test/model-1"
    assert result["latency_ms"] >= 0
    calls = (stub / "calls.txt").read_text()
    assert "--no-stream --raw" in calls
    assert "-m test/model-1" in calls
    assert "RETRIES=0" in calls

    # read-only: health visible, probe blocked (it spends money)
    ro = TestClient(create_app(root, read_only=True))
    assert ro.get("/api/llm-health").status_code == 200
    assert ro.post("/api/llm-health/probe").status_code == 403


def test_probe_failure_shape(tmp_path: Path, monkeypatch):
    root = _mk_identity(tmp_path, _thoughts(20, 2, 10))
    stub = tmp_path / "stub-bin"
    stub.mkdir()
    script = stub / "llm"
    script.write_text(
        "#!/usr/bin/env bash\n"
        'echo "llm: error: API error: Provider returned error" >&2\nexit 1\n'
    )
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setattr(control, "BIN_DIR", stub)

    client = TestClient(create_app(root))
    result = client.post("/api/llm-health/probe").json()
    assert result["ok"] is False
    assert "Provider returned error" in result["error"]


# --- last_call marker (bin/llm writes state-home/run/llm_health.json) -----------


def _write_marker(home: Path, payload: dict) -> None:
    (home / "run").mkdir(parents=True, exist_ok=True)
    (home / "run" / "llm_health.json").write_text(json.dumps(payload))


def test_last_call_absent(tmp_path: Path, monkeypatch):
    monkeypatch.setenv("HEADLONG_HOME", str(tmp_path / "home"))
    assert llm_health.last_call() is None


def test_last_call_credit_failure_overrides_status(tmp_path: Path, monkeypatch):
    home = tmp_path / "home"
    monkeypatch.setenv("HEADLONG_HOME", str(home))
    _write_marker(
        home,
        {
            "ok": False,
            "ts": "2026-08-22T09:00:00Z",
            "provider": "openrouter",
            "model": "anthropic/claude-sonnet-4.5",
            "kind": "credit",
            "http_code": 402,
            "message": "Insufficient credits. Add more using https://openrouter.ai/settings/credits",
        },
    )
    root = _mk_identity(tmp_path, _thoughts(12, newest_minutes_ago=1, gap_s=30))
    llm_health._cache.update(ts=0.0, root=None, payload=None)
    payload = llm_health.llm_health(root)
    assert payload["status"] == "erroring"
    last = payload["last_call"]
    assert last["ok"] is False
    assert last["kind"] == "credit"
    assert last["http_code"] == 402
    assert last["provider"] == "openrouter"
    assert "Insufficient credits" in last["message"]


def test_last_call_ok_keeps_passive_status(tmp_path: Path, monkeypatch):
    home = tmp_path / "home"
    monkeypatch.setenv("HEADLONG_HOME", str(home))
    _write_marker(home, {"ok": True, "ts": "2026-08-22T09:00:00Z", "provider": "anthropic", "model": "m"})
    root = _mk_identity(tmp_path, _thoughts(12, newest_minutes_ago=1, gap_s=30))
    llm_health._cache.update(ts=0.0, root=None, payload=None)
    payload = llm_health.llm_health(root)
    assert payload["status"] == "ok"
    assert payload["last_call"] == {
        "ok": True,
        "ts": "2026-08-22T09:00:00Z",
        "provider": "anthropic",
        "model": "m",
        "identity": None,
        "kind": None,
        "http_code": None,
        "message": None,
    }


def test_last_call_budget_names_the_identity_and_keeps_passive_status(tmp_path: Path, monkeypatch):
    # The spend limit stopping a call is not the provider failing: the
    # marker says whose limit it was, and the provider status stays passive.
    home = tmp_path / "home"
    monkeypatch.setenv("HEADLONG_HOME", str(home))
    _write_marker(home, {"ok": False, "ts": "2026-08-22T09:00:00Z", "provider": "openrouter",
                         "model": "m", "identity": "probe", "kind": "budget", "http_code": None,
                         "message": "spend limit reached: $25.01 of $25 in total; no request sent"})
    root = _mk_identity(tmp_path, _thoughts(12, newest_minutes_ago=1, gap_s=30))
    llm_health._cache.update(ts=0.0, root=None, payload=None)
    payload = llm_health.llm_health(root)
    assert payload["status"] == "ok"
    assert payload["last_call"]["kind"] == "budget"
    assert payload["last_call"]["identity"] == "probe"


def test_last_call_garbage_ignored(tmp_path: Path, monkeypatch):
    home = tmp_path / "home"
    monkeypatch.setenv("HEADLONG_HOME", str(home))
    (home / "run").mkdir(parents=True)
    (home / "run" / "llm_health.json").write_text("{not json")
    assert llm_health.last_call() is None
