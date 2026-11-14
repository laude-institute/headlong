"""LLM provider health, inferred from what the mind logs already record.

Passive signals only — no LLM calls are made here:
- failure markers: the inner monologue's placeholder thoughts ("empty
  response from the LLM") and the actor's failure observations
  ("action failed: ..."), both timestamped steps in the trajectory;
- thought cadence: median gap between consecutive inner_monologue steps,
  recent window vs baseline — a provider-latency proxy.

The active probe (an actual tiny LLM call) lives in control.llm_probe.
"""

import json
import os
import re
import time
from datetime import datetime, timezone
from pathlib import Path
from statistics import median

from headlong_web import discovery, liveness
from headlong_web.env import getenv

# Scan at most this much of the tail of each mind log
_TAIL_BYTES = 400 * 1024
# Serve cached results briefly: the dash polls, files don't change that fast
_CACHE_TTL_S = 15

_PLACEHOLDER_MARKER = "empty response from the LLM"
_FAILURE_PREFIX = "action failed:"

_TS_FIXUP = re.compile(r"([+-]\d{2})(\d{2})$")

_cache: dict = {"ts": 0.0, "root": None, "payload": None}


def _parse_ts(ts: str) -> float | None:
    """ISO ts -> epoch seconds; naive timestamps are assumed UTC."""
    if not ts:
        return None
    try:
        parsed = datetime.fromisoformat(_TS_FIXUP.sub(r"\1:\2", ts))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.timestamp()


def _tail_steps(jsonl: Path) -> list[dict]:
    try:
        size = jsonl.stat().st_size
        with jsonl.open("rb") as fh:
            if size > _TAIL_BYTES:
                fh.seek(size - _TAIL_BYTES)
                fh.readline()  # drop the partial line
            raw = fh.read().decode("utf-8", errors="replace")
    except OSError:
        return []
    steps = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            step = json.loads(line)
        except ValueError:
            continue
        if isinstance(step, dict):
            steps.append(step)
    return steps


def _is_failure_step(step: dict) -> bool:
    content = str(step.get("content") or "")
    if step.get("type") == "thought" and _PLACEHOLDER_MARKER in content:
        return True
    if step.get("type") == "observation" and content.startswith(_FAILURE_PREFIX):
        return True
    return False


def _cadence(steps: list[dict]) -> dict | None:
    """Median gap between consecutive inner_monologue steps: recent vs prior."""
    times = [
        ts
        for step in steps
        if step.get("source") == "inner_monologue"
        and (ts := _parse_ts(str(step.get("ts") or ""))) is not None
    ]
    gaps = [b - a for a, b in zip(times, times[1:]) if 0 < b - a < 3600]
    if len(gaps) < 8:
        return None
    recent = gaps[-20:]
    baseline = gaps[:-20][-150:]
    return {
        "recent_median_s": round(median(recent), 1),
        "baseline_median_s": round(median(baseline), 1) if len(baseline) >= 8 else None,
        "recent_n": len(recent),
    }


def _identity_signals(identity: discovery.IdentityInfo, now: float) -> dict | None:
    traj_dir = discovery.find_root_traj_dir(identity)
    if traj_dir is None:
        return None
    jsonl = traj_dir / "trajectory.jsonl"
    steps = _tail_steps(jsonl)
    if not steps:
        return None

    failures_1h = 0
    failures_15m = 0
    last_failure = None
    any_recent_activity = False
    for step in steps:
        ts = _parse_ts(str(step.get("ts") or ""))
        if ts is None:
            continue
        if now - ts <= 3600:
            any_recent_activity = True
        if not _is_failure_step(step):
            continue
        if now - ts <= 3600:
            failures_1h += 1
            if now - ts <= 900:
                failures_15m += 1
            last_failure = {
                "ts": step.get("ts"),
                "content": str(step.get("content") or "")[:160],
            }

    live = liveness.identity_status(identity.path, jsonl)["live"]
    if not any_recent_activity and not live:
        return None  # dormant identity: no signal either way

    return {
        "id": identity.id,
        "name": identity.name,
        "live": live,
        "failures_1h": failures_1h,
        "failures_15m": failures_15m,
        "last_failure": last_failure,
        "cadence": _cadence(steps) if live else None,
    }


def _state_home() -> Path:
    """Same resolution as bin/llm: HEADLONG_HOME, SHELLM_HOME, ~/.headlong."""
    return Path(getenv("HEADLONG_HOME") or os.path.expanduser("~/.headlong"))


def last_call() -> dict | None:
    """The marker bin/llm rewrites after every call (state home, run/llm_health.json):
    ok, or a classified failure (credit / auth / rate / budget / other), and
    whose call it was when known. None if absent."""
    path = _state_home() / "run" / "llm_health.json"
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or "ok" not in data:
        return None
    return {
        "ok": bool(data.get("ok")),
        "ts": data.get("ts"),
        "provider": data.get("provider") or None,
        "model": data.get("model") or None,
        "identity": data.get("identity") or None,
        "kind": data.get("kind"),
        "http_code": data.get("http_code"),
        "message": data.get("message"),
    }


def llm_health(root: Path) -> dict:
    now = time.time()
    if (
        _cache["payload"] is not None
        and _cache["root"] == root
        and now - _cache["ts"] < _CACHE_TTL_S
    ):
        return _cache["payload"]

    identities = []
    for identity in discovery.scan_identities(root):
        signals = _identity_signals(identity, now)
        if signals is not None:
            identities.append(signals)

    failures_15m = sum(i["failures_15m"] for i in identities)
    failures_1h = sum(i["failures_1h"] for i in identities)
    slow = any(
        (c := i.get("cadence"))
        and c.get("baseline_median_s")
        and c["recent_median_s"] > 1.75 * c["baseline_median_s"]
        for i in identities
    )

    last = last_call()
    if failures_15m >= 3:
        status = "erroring"
    elif failures_1h >= 1 or slow:
        status = "degraded"
    elif identities:
        status = "ok"
    else:
        status = "unknown"
    # A hard failure on the last real call (out of credit, bad key) is the
    # loudest signal there is; it overrides the passive inference.
    if last and not last["ok"] and last.get("kind") in ("credit", "auth"):
        status = "erroring"

    payload = {
        "status": status,
        "failures_15m": failures_15m,
        "failures_1h": failures_1h,
        "cadence_slow": slow,
        "identities": identities,
        "last_call": last,
        "checked_at": datetime.now(tz=timezone.utc).isoformat(),
    }
    _cache.update(ts=now, root=root, payload=payload)
    return payload
