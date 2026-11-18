"""Usage series: incremental cache over the mind log + llm ledger, and the
API (serve cache, refresh, lock)."""

import json
import shutil
import stat
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from headlong_web import control, usage
from headlong_web.server import create_app

ROOT_TRAJ = "efefefef-9999-4999-8999-999999999999"


def _row(**fields) -> str:
    return json.dumps(fields) + "\n"


def _run_rows(day: str, run_id: str, model: str, in_tok: int, out_tok: int, think_tok: int) -> str:
    return (
        _row(type="shellm-run", step_id=run_id, model=model, ts=f"{day}T10:00:00Z")
        + _row(type="reasoning", step_id=f"{run_id}-r1", run_id=run_id, thought="x",
               in_tok=in_tok, out_tok=out_tok, think_tok=think_tok, ts=f"{day}T10:00:05Z")
        + _row(type="shell-output", step_id=f"{run_id}-o1", run_id=run_id, ts=f"{day}T10:00:06Z")
        + _row(type="reasoning", step_id=f"{run_id}-r2", run_id=run_id, thought="y",
               ts=f"{day}T10:00:09Z")  # no usage stamped: counts as a step, not a call
    )


def _ledger_row(day: str, model: str, in_tok: int, out_tok: int, think_tok: int | None = None,
                hhmm: str = "12:00") -> str:
    fields = {"ts": f"{day}T{hhmm}:00Z", "provider": "openrouter", "model": model,
              "in_tok": in_tok, "out_tok": out_tok}
    if think_tok is not None:
        fields["think_tok"] = think_tok
    return json.dumps(fields) + "\n"


def _cost_row(day: str, model: str, cost, hhmm: str = "12:00", **extra) -> str:
    fields = {"ts": f"{day}T{hhmm}:00Z", "provider": "openrouter", "model": model,
              "in_tok": 10, "out_tok": 1, "cost": cost, **extra}
    return json.dumps(fields) + "\n"


@pytest.fixture
def identity(tmp_path: Path) -> Path:
    ident = tmp_path / ".identities" / "usr"
    ident.mkdir(parents=True)
    (ident / "info.txt").write_text(
        f"name=usr\ncreated=2026-08-01T00:00:00\nroot_trajectory={ROOT_TRAJ}\n"
    )
    traj = ident / "trajectories" / "efefefef-root"
    traj.mkdir(parents=True)
    log = (
        _row(type="trajectory", step_id=ROOT_TRAJ, ts="2026-08-01T09:00:00Z")
        + _row(type="message", step_id="m1", **{"from": "nick", "to": "usr"}, content="hi",
               ts="2026-08-01T09:30:00-0700")  # 16:30Z, still 08-01
        + _run_rows("2026-08-01", "run1", "modelA", 1000, 50, 10)
        + _row(type="message", step_id="m2", **{"from": "usr", "to": "nick"}, content="hello",
               ts="2026-08-01T17:00:00Z")
        + _row(type="message", step_id="m3", **{"from": "usr", "to": "usr"}, content="self-note",
               ts="2026-08-01T17:05:00Z")  # to itself: neither in nor out
        + _run_rows("2026-08-02", "run2", "modelB", 2000, 80, 0)
        + "not json at all\n"
        + _row(type="thought", step_id="t-no-ts", content="no ts")
    )
    (traj / "trajectory.jsonl").write_text(log)
    return ident


@pytest.fixture
def traj_dir(identity: Path) -> Path:
    return identity / "trajectories" / "efefefef-root"


@pytest.fixture
def ledger(identity: Path) -> Path:
    return usage.ledger_path(identity)


@pytest.fixture
def client(identity: Path) -> TestClient:
    return TestClient(create_app(identity.parent.parent))


def _wait_until_done(traj_dir: Path) -> None:
    for _ in range(100):
        if not usage.is_refreshing(traj_dir) and usage.load(traj_dir):
            return
        time.sleep(0.02)
    raise AssertionError("usage refresh never finished")


def _day(state: dict, day: str) -> dict:
    return state["daily"][day]


# --- module: mind log only ---------------------------------------------------

def test_refresh_builds_daily_series(traj_dir: Path):
    state = usage.refresh(traj_dir, "usr")
    assert state["rows"] == 14
    assert state["skipped"] == 2  # bad json + missing ts
    d1 = _day(state, "2026-08-01")
    assert d1["in_msg"] == 1 and d1["out_msg"] == 1
    assert d1["runs"] == 1 and d1["reasoning"] == 2
    assert d1["run"]["calls"] == 1
    assert (d1["run"]["in"], d1["run"]["out"], d1["run"]["think"]) == (1000, 50, 10)
    assert d1["run"]["models"] == {"modelA": {"calls": 1, "in": 1000, "out": 50, "think": 10}}
    assert d1["llm"]["calls"] == 0
    d2 = _day(state, "2026-08-02")
    assert d2["in_msg"] == 0 and d2["run"]["calls"] == 1 and d2["run"]["in"] == 2000
    assert state["log_offset"] == (traj_dir / "trajectory.jsonl").stat().st_size
    assert state["ledger_offset"] == 0
    assert usage.load(traj_dir)["rows"] == 14


def test_refresh_is_incremental(traj_dir: Path, monkeypatch):
    usage.refresh(traj_dir, "usr")
    log = traj_dir / "trajectory.jsonl"
    # Appended rows (plus a half-written last row) are folded in; nothing is
    # double counted. The half row is picked up once it is complete.
    with log.open("a") as fh:
        fh.write(_run_rows("2026-08-03", "run3", "modelA", 500, 5, 1))
        fh.write('{"type": "message", "from": "nick", "to": "usr"')  # no newline: partial
    calls = []
    real_ingest = usage._ingest_log
    monkeypatch.setattr(usage, "_ingest_log",
                        lambda st, line, name: (calls.append(line), real_ingest(st, line, name)))
    state = usage.refresh(traj_dir, "usr")
    assert len(calls) == 4
    assert state["rows"] == 18
    assert _day(state, "2026-08-03")["run"]["in"] == 500
    assert state["log_offset"] < log.stat().st_size
    with log.open("a") as fh:
        fh.write(', "ts": "2026-08-03T12:00:00Z"}\n')
    state = usage.refresh(traj_dir, "usr")
    assert _day(state, "2026-08-03")["in_msg"] == 1
    assert state["log_offset"] == log.stat().st_size


def test_refresh_rebuilds_when_log_shrinks(traj_dir: Path):
    usage.refresh(traj_dir, "usr")
    log = traj_dir / "trajectory.jsonl"
    log.write_text(_row(type="trajectory", step_id=ROOT_TRAJ, ts="2026-08-05T00:00:00Z"))
    state = usage.refresh(traj_dir, "usr")
    assert state["rows"] == 1
    assert list(state["daily"]) == ["2026-08-05"]


def test_rebuild_flag_starts_from_scratch(traj_dir: Path):
    state = usage.refresh(traj_dir, "usr")
    _day(state, "2026-08-01")["in_msg"] = 99
    usage._write(traj_dir, state)
    assert _day(usage.refresh(traj_dir, "usr"), "2026-08-01")["in_msg"] == 99
    assert _day(usage.refresh(traj_dir, "usr", rebuild=True), "2026-08-01")["in_msg"] == 1


def test_old_cache_version_is_rebuilt(traj_dir: Path):
    state = usage.refresh(traj_dir, "usr")
    state["version"] = 1
    state["rows"] = 999
    usage._write(traj_dir, state)
    assert usage.load(traj_dir) is None
    assert usage.refresh(traj_dir, "usr")["rows"] == 14


def test_stale_lock_is_ignored(traj_dir: Path):
    lock = usage.lock_path(traj_dir)
    lock.mkdir(parents=True)
    assert usage.is_refreshing(traj_dir)
    import os
    old = time.time() - usage.STALE_LOCK_S - 5
    os.utime(lock, (old, old))
    assert not usage.is_refreshing(traj_dir)
    assert not lock.exists()


# --- module: ledger ---------------------------------------------------------

def test_ledger_wins_per_day_and_older_days_fall_back(traj_dir: Path, ledger: Path):
    # The ledger starts on 08-02: that day and later come from the ledger
    # (every llm call, including ones outside shellm runs); 08-01 keeps the
    # mind-log stamps.
    ledger.parent.mkdir(parents=True)
    ledger.write_text(
        _ledger_row("2026-08-02", "modelB", 2000, 80, 0, "10:00")     # the run2 call
        + _ledger_row("2026-08-02", "fast/model", 300, 20, None, "11:00")  # responder fast path
        + _ledger_row("2026-08-03", "modelA", 700, 9, 2)
        + "garbage\n"
        + json.dumps({"ts": "2026-08-03T01:00:00Z", "model": "x"}) + "\n"  # no tokens: skipped
    )
    state = usage.refresh(traj_dir, "usr", ledger=ledger)
    assert state["ledger_rows"] == 5 and state["ledger_skipped"] == 2
    assert state["ledger_offset"] == ledger.stat().st_size
    d2 = _day(state, "2026-08-02")
    assert d2["run"]["calls"] == 1 and d2["run"]["in"] == 2000       # stamps kept raw
    assert d2["llm"]["calls"] == 2 and d2["llm"]["in"] == 2300      # ledger alongside
    assert set(d2["llm"]["models"]) == {"modelB", "fast/model"}

    body = usage.summary(traj_dir, "id", "usr", ledger=ledger)
    days = dict(body["daily"])
    assert days["2026-08-01"]["source"] == "mindlog"
    assert days["2026-08-01"]["calls"] == 1 and days["2026-08-01"]["in"] == 1000
    assert days["2026-08-02"]["source"] == "ledger"
    assert days["2026-08-02"]["calls"] == 2 and days["2026-08-02"]["in"] == 2300
    assert days["2026-08-02"]["runs"] == 1 and days["2026-08-02"]["reasoning"] == 2
    assert days["2026-08-03"] == {
        "rows": 0, "in_msg": 0, "out_msg": 0, "runs": 0, "reasoning": 0,
        "calls": 1, "in": 700, "out": 9, "think": 2, "cost_llm": 0, "cost_opencode": 0,
        "source": "ledger",
    }
    assert body["by_model"] == {
        "modelA": {"calls": 2, "in": 1700, "out": 59, "think": 12, "cost": 0},  # 08-01 stamp + 08-03 ledger
        "modelB": {"calls": 1, "in": 2000, "out": 80, "think": 0, "cost": 0},
        "fast/model": {"calls": 1, "in": 300, "out": 20, "think": 0, "cost": 0},
    }
    assert body["totals"]["in"] == 4000 and body["totals"]["calls"] == 4
    assert body["ledger"] == {"rows": 5, "skipped": 2, "since": "2026-08-02", "calls": 3, "priced": 0}
    assert body["pending_bytes"] == 0


def test_ledger_is_incremental_and_rebuilds_when_it_shrinks(traj_dir: Path, ledger: Path):
    ledger.parent.mkdir(parents=True)
    ledger.write_text(_ledger_row("2026-08-04", "m", 10, 1))
    state = usage.refresh(traj_dir, "usr", ledger=ledger)
    with ledger.open("a") as fh:
        fh.write(_ledger_row("2026-08-04", "m", 20, 2))
        fh.write('{"ts": "2026-08-04T13:00:00Z", "model": "m", "in_tok": 5')  # partial
    state = usage.refresh(traj_dir, "usr", ledger=ledger)
    assert _day(state, "2026-08-04")["llm"] == {
        "calls": 2, "in": 30, "out": 3, "think": 0,
        "models": {"m": {"calls": 2, "in": 30, "out": 3, "think": 0}},
    }
    assert usage.summary(traj_dir, "id", "usr", ledger=ledger)["pending_bytes"] > 0
    ledger.write_text(_ledger_row("2026-08-06", "m", 1, 1))   # rotated: smaller
    state = usage.refresh(traj_dir, "usr", ledger=ledger)
    assert "2026-08-04" not in state["daily"]
    assert _day(state, "2026-08-06")["llm"]["calls"] == 1
    assert state["rows"] == 14   # the log was re-read too


def test_partial_ledger_day_keeps_the_stamps(traj_dir: Path, ledger: Path):
    # The ledger started mid-day on 08-01 (one line) while the stamps already
    # have one call plus later ones: fewer ledger calls than stamps means the
    # ledger is partial for that day, so the stamps stand. 08-02 has one
    # stamp and one ledger line (equal): the ledger wins.
    log = traj_dir / "trajectory.jsonl"
    with log.open("a") as fh:
        fh.write(_run_rows("2026-08-01", "run9", "modelA", 10, 1, 0))   # 2 stamped calls on 08-01
    ledger.parent.mkdir(parents=True)
    ledger.write_text(
        _ledger_row("2026-08-01", "modelA", 10, 1, 0, "10:00")
        + _ledger_row("2026-08-02", "modelB", 2000, 80, 0, "10:00")
    )
    usage.refresh(traj_dir, "usr", ledger=ledger)
    body = usage.summary(traj_dir, "id", "usr", ledger=ledger)
    days = dict(body["daily"])
    assert days["2026-08-01"]["source"] == "mindlog"
    assert days["2026-08-01"]["calls"] == 2 and days["2026-08-01"]["in"] == 1010
    assert days["2026-08-02"]["source"] == "ledger"
    assert body["ledger"]["since"] == "2026-08-02"


def test_missing_ledger_is_fine(traj_dir: Path, ledger: Path):
    state = usage.refresh(traj_dir, "usr", ledger=ledger)
    assert state["ledger_rows"] == 0 and state["ledger_offset"] == 0
    body = usage.summary(traj_dir, "id", "usr", ledger=ledger)
    assert body["ledger"] == {"rows": 0, "skipped": 0, "since": None, "calls": 0, "priced": 0}
    assert all(d["source"] == "mindlog" for _, d in body["daily"])


def test_ledger_cost_by_day_model_and_spender(traj_dir: Path, ledger: Path):
    # Cost comes from the ledger, bin/llm's calls and contrib/opencode's
    # delegation steps apart. A line with a cost but no tokens still counts,
    # as it does for bin/llm's spend limit, even on a day whose tokens come
    # from the mind log; priced says how many token calls had a cost.
    ledger.parent.mkdir(parents=True)
    ledger.write_text(
        _cost_row("2026-08-02", "modelB", 0.1, "10:00")
        + _cost_row("2026-08-02", "modelB", 0.2, "11:00")
        + _cost_row("2026-08-02", "openai/gpt-x", 0.05, "12:00", source="opencode", delegation="d1")
        + _ledger_row("2026-08-02", "modelB", 5, 1, None, "13:00")     # no cost
        + _ledger_row("2026-08-02", "other/model", 5, 1, None, "14:00")  # no cost
        + json.dumps({"ts": "2026-08-03T01:00:00Z", "model": "modelB", "cost": 0.4}) + "\n"
        + json.dumps({"ts": "2026-08-03T02:00:00Z", "model": "modelB", "cost": True}) + "\n"
    )
    usage.refresh(traj_dir, "usr", ledger=ledger)
    body = usage.summary(traj_dir, "id", "usr", ledger=ledger)
    days = dict(body["daily"])
    assert days["2026-08-02"]["cost_llm"] == 0.3        # 0.1 + 0.2, float noise rounded away
    assert days["2026-08-02"]["cost_opencode"] == 0.05
    assert days["2026-08-03"]["source"] == "mindlog" and days["2026-08-03"]["cost_llm"] == 0.4
    assert days["2026-08-01"]["cost_llm"] == 0
    assert body["by_model"]["modelB"]["cost"] == 0.7
    assert body["by_model"]["openai/gpt-x"]["cost"] == 0.05
    assert body["by_model"]["other/model"]["cost"] == 0
    assert body["totals"]["cost_llm"] == 0.7 and body["totals"]["cost_opencode"] == 0.05
    assert body["ledger"]["calls"] == 5 and body["ledger"]["priced"] == 4


# --- API ------------------------------------------------------------------

def test_usage_unavailable(client: TestClient):
    body = client.get("/api/identities/.identities~usr/usage").json()
    assert body["available"] is False
    assert body["refreshing"] is False
    assert body["identity"] == {"id": ".identities~usr", "name": "usr"}
    assert body["pending_bytes"] > 0


def test_usage_refresh_then_serve(client: TestClient, traj_dir: Path, ledger: Path):
    ledger.parent.mkdir(parents=True)
    ledger.write_text(_ledger_row("2026-08-03", "modelC", 40, 4, 1))
    resp = client.post("/api/identities/.identities~usr/usage/refresh", json={})
    assert resp.status_code == 202, resp.text
    assert resp.json() == {"ok": True, "action": "usage-refresh", "rebuild": False}
    _wait_until_done(traj_dir)
    body = client.get("/api/identities/.identities~usr/usage").json()
    assert body["available"] is True
    assert body["pending_bytes"] == 0
    assert [d for d, _ in body["daily"]] == ["2026-08-01", "2026-08-02", "2026-08-03"]
    assert body["totals"] == {
        "in": 3040, "out": 134, "think": 11, "calls": 3, "in_msg": 1, "out_msg": 1, "runs": 2,
        "cost_llm": 0, "cost_opencode": 0,
    }
    assert set(body["by_model"]) == {"modelA", "modelB", "modelC"}
    assert body["skipped"] == 2
    assert body["ledger"]["since"] == "2026-08-03"


def test_usage_rebuild_via_api(client: TestClient, traj_dir: Path):
    state = usage.refresh(traj_dir, "usr")
    _day(state, "2026-08-01")["in_msg"] = 99
    usage._write(traj_dir, state)
    resp = client.post("/api/identities/.identities~usr/usage/refresh", json={"rebuild": True})
    assert resp.status_code == 202
    assert resp.json()["rebuild"] is True
    _wait_until_done(traj_dir)
    body = client.get("/api/identities/.identities~usr/usage").json()
    assert dict(body["daily"])["2026-08-01"]["in_msg"] == 1


def test_usage_refresh_conflicts_with_lock(client: TestClient, traj_dir: Path):
    usage.lock_path(traj_dir).mkdir(parents=True)
    resp = client.post("/api/identities/.identities~usr/usage/refresh", json={})
    assert resp.status_code == 409
    assert client.get("/api/identities/.identities~usr/usage").json()["refreshing"] is True


def test_usage_refresh_read_only(identity: Path, traj_dir: Path):
    ro = TestClient(create_app(identity.parent.parent, read_only=True))
    resp = ro.post("/api/identities/.identities~usr/usage/refresh", json={})
    assert resp.status_code == 403
    assert ro.get("/api/identities/.identities~usr/usage").status_code == 200



# --- spend limit: GET .../spend asks llm --spend ------------------------------

def _stub_llm(tmp_path: Path, monkeypatch, body: str) -> Path:
    stub = tmp_path / "stub-bin"
    stub.mkdir()
    script = stub / "llm"
    script.write_text("#!/usr/bin/env bash\n"
                      f'echo "ARGS=$* IDENTITY_DIR=$IDENTITY_DIR" >> {stub}/calls.txt\n' + body)
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setattr(control, "BIN_DIR", stub)
    control._spend_cache.clear()
    return stub


def test_spend_serves_llm_spend_for_the_identity(client: TestClient, identity: Path,
                                                 tmp_path: Path, monkeypatch):
    stub = _stub_llm(tmp_path, monkeypatch, (
        "printf '{\"spent\":1.5,\"limit\":2,\"remaining\":0.5,\"window\":\"day\","
        "\"since\":\"2026-08-02T00:00:00Z\",\"ledger\":\"/x/llm.jsonl\",\"identity\":\"usr\"}'\n"))
    body = client.get("/api/identities/.identities~usr/spend").json()
    assert body == {"ok": True, "spent": 1.5, "limit": 2, "remaining": 0.5, "window": "day",
                    "since": "2026-08-02T00:00:00Z"}
    calls = (stub / "calls.txt").read_text().splitlines()
    assert calls == [f"ARGS=--spend IDENTITY_DIR={identity}"]
    # Polled by the usage page: served from a short cache, read-only too.
    ro = TestClient(create_app(identity.parent.parent, read_only=True))
    assert ro.get("/api/identities/.identities~usr/spend").json() == body
    assert len((stub / "calls.txt").read_text().splitlines()) == 1


def test_spend_reports_rejected_settings(client: TestClient, tmp_path: Path, monkeypatch):
    _stub_llm(tmp_path, monkeypatch,
              "echo \"llm: error: LLM_SPEND_WINDOW must be total, day or month (got 'week')\" >&2\n"
              "exit 1\n")
    body = client.get("/api/identities/.identities~usr/spend").json()
    assert body == {"ok": False,
                    "error": "llm: error: LLM_SPEND_WINDOW must be total, day or month (got 'week')"}


@pytest.mark.skipif(shutil.which("jq") is None, reason="bin/llm needs jq")
def test_spend_runs_the_real_llm_with_the_identity_env(client: TestClient, identity: Path,
                                                      ledger: Path, tmp_path: Path, monkeypatch):
    # The limit is in the identity's .env, as docs/install.md says; bin/llm
    # sums the ledger's cost, OpenCode delegation steps included.
    monkeypatch.setenv("HEADLONG_HOME", str(tmp_path / "state"))  # not the developer's own .env
    for var in ("LLM_SPEND_LIMIT_USD", "LLM_SPEND_WINDOW", "LLM_USAGE_LEDGER"):
        monkeypatch.delenv(var, raising=False)
    control._spend_cache.clear()
    (identity / ".env").write_text("LLM_SPEND_LIMIT_USD=1\n")
    ledger.parent.mkdir(parents=True)
    ledger.write_text(_cost_row("2026-08-02", "m", 0.25)
                      + _cost_row("2026-08-02", "m", 0.5, "13:00", source="opencode"))
    body = client.get("/api/identities/.identities~usr/spend").json()
    assert body == {"ok": True, "spent": 0.75, "limit": 1, "remaining": 0.25, "window": "total",
                    "since": None}
