"""Per-day usage series for an identity, with an incremental cache.

What the usage page shows: messages in/out, model calls, tokens (input,
output, thinking), cost, agentic runs started and reasoning steps, per UTC
day, plus token and cost totals per model. The same definitions as
deploy/scripts/audel-metrics, computed locally.

Two append-only sources feed it:

* the mind log (``<traj_dir>/trajectory.jsonl``) for messages, runs and
  reasoning steps. Reasoning steps written by bin/shellm also carry the
  tokens of their model call (``in_tok``/``out_tok``/``think_tok``); the
  model lives on the run's ``shellm-run`` row, joined via ``run_id``.
* the usage ledger (``<identity_dir>/usage/llm.jsonl``), one line per
  successful bin/llm call from any caller (shellm runs, the responder's
  fast path, other thinkers, hand calls), with ts/model/tokens. bin/llm
  appends it unconditionally, so it is the complete spend. Lines carry
  ``cost`` (USD) when the provider reported one (OpenRouter's usage.cost);
  contrib/opencode appends one line per delegation step with
  ``source: "opencode"``. Cost always comes from the ledger, whichever
  source wins a day's tokens: the mind log has none, and it is the sum
  bin/llm's spend limit (LLM_SPEND_LIMIT_USD) counts.

Per day, the ledger wins when it has at least as many calls as the stamps
(a complete ledger is a superset of the stamps); days before the ledger
existed, the part-day it started on, or a day where it could not be written
fall back to the mind-log stamps, which cover shellm runs only. The API
marks each day with its ``source`` so the page can say what the numbers
cover.

The cache (``<traj_dir>/usage/cache.json``) keeps the per-day counters, the
run_id -> model map and the byte offset read so far in each file. A refresh
reads only the bytes appended since the last one, so the first build is one
pass over both files and every refresh after that costs a fraction of a
second. Nothing is computed on GET: the page serves the cache and a refresh
is an explicit POST, so a dash sitting open burns no CPU.

A ``.lock`` directory marks a refresh in progress (same convention as the
recap cache); the API reports it as ``refreshing``.
"""

import json
import os
import re
import shutil
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

CACHE_VERSION = 3
CACHE_DIRNAME = "usage"
CACHE_FILE = "cache.json"
LOCK_DIRNAME = ".lock"
LEDGER_FILE = "llm.jsonl"
# A lock older than this is a crashed refresh, not a running one.
STALE_LOCK_S = 15 * 60

COUNT_KEYS = ("rows", "in_msg", "out_msg", "runs", "reasoning")
TOKEN_KEYS = ("calls", "in", "out", "think")
TOKEN_FIELDS = (("in_tok", "in"), ("out_tok", "out"), ("think_tok", "think"))

_OFFSET_FIX = re.compile(r"([+-][0-9]{2})([0-9]{2})$")


def _epoch(ts: str) -> float | None:
    ts = (ts or "").strip()
    if not ts:
        return None
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(_OFFSET_FIX.sub(r"\1:\2", ts))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.timestamp()


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def cache_dir(traj_dir: Path) -> Path:
    return traj_dir / CACHE_DIRNAME


def cache_path(traj_dir: Path) -> Path:
    return cache_dir(traj_dir) / CACHE_FILE


def lock_path(traj_dir: Path) -> Path:
    return cache_dir(traj_dir) / LOCK_DIRNAME


def ledger_path(identity_dir: Path) -> Path:
    """Where bin/llm appends its usage ledger for this identity."""
    return identity_dir / "usage" / LEDGER_FILE


def is_refreshing(traj_dir: Path) -> bool:
    lock = lock_path(traj_dir)
    if not lock.is_dir():
        return False
    try:
        age = time.time() - lock.stat().st_mtime
    except OSError:
        return False
    if age > STALE_LOCK_S:
        shutil.rmtree(lock, ignore_errors=True)
        return False
    return True


def _empty_tokens() -> dict:
    return {"calls": 0, "in": 0, "out": 0, "think": 0, "models": {}}


def _empty_day() -> dict:
    day = dict.fromkeys(COUNT_KEYS, 0)
    day["run"] = _empty_tokens()   # from mind-log stamps (shellm runs)
    day["llm"] = _empty_tokens()   # from the bin/llm ledger (every call)
    # From the ledger too: USD by who spent it, and how many lines had a cost.
    day["cost"] = {"llm": 0.0, "opencode": 0.0, "priced": 0}
    return day


def _empty_state(identity_name: str) -> dict:
    return {
        "version": CACHE_VERSION,
        "identity": identity_name,
        "generated": None,
        "log_offset": 0,
        "ledger_offset": 0,
        "rows": 0,
        "skipped": 0,
        "ledger_rows": 0,
        "ledger_skipped": 0,
        "daily": {},
        "run_model": {},
    }


def load(traj_dir: Path) -> dict | None:
    """The cached state, or None when there is none (or it is unreadable /
    from an older version, which means: rebuild)."""
    try:
        state = json.loads(cache_path(traj_dir).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(state, dict) or state.get("version") != CACHE_VERSION:
        return None
    return state


def _write(traj_dir: Path, state: dict) -> None:
    target = cache_path(traj_dir)
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(target.parent), prefix=".cache-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(state, fh, separators=(",", ":"))
        os.replace(tmp, target)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _parse_row(line: bytes) -> tuple[dict, str] | None:
    """(row, day) for a JSON row with a parseable ts, else None."""
    try:
        row = json.loads(line)
    except ValueError:
        return None
    if not isinstance(row, dict):
        return None
    ts = _epoch(str(row.get("ts") or ""))
    if ts is None:
        return None
    return row, datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d")


def _day(state: dict, day_key: str) -> dict:
    day = state["daily"].get(day_key)
    if day is None:
        day = state["daily"][day_key] = _empty_day()
    return day


def _add_tokens(bucket: dict, row: dict, model: str) -> bool:
    """Fold one call's tokens into a day bucket (and its per-model map).
    Returns whether any token field was present."""
    stamped = False
    per_model = bucket["models"].get(model)
    if per_model is None:
        per_model = bucket["models"][model] = dict.fromkeys(TOKEN_KEYS, 0)
    for field, short in TOKEN_FIELDS:
        value = row.get(field)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            bucket[short] += int(value)
            per_model[short] += int(value)
            stamped = True
    if stamped:
        bucket["calls"] += 1
        per_model["calls"] += 1
    return stamped


def _ingest_log(state: dict, line: bytes, identity_name: str) -> None:
    """Fold one mind-log row into the state. Rows without a parseable ts are
    counted as skipped (they carry no day to land in)."""
    state["rows"] += 1
    parsed = _parse_row(line)
    if parsed is None:
        state["skipped"] += 1
        return
    step, day_key = parsed
    day = _day(state, day_key)
    day["rows"] += 1

    kind = step.get("type") or ""
    rid = step.get("run_id") or ""
    if kind == "shellm-run":
        day["runs"] += 1
        # The run's own step_id is the run_id its reasoning/final steps carry.
        sid = step.get("step_id")
        if sid:
            state["run_model"][str(sid)] = str(step.get("model") or "?")
    elif kind == "message":
        frm, to = step.get("from") or "", step.get("to") or ""
        if to == identity_name and frm and frm != identity_name:
            day["in_msg"] += 1
        elif frm == identity_name and to and to != identity_name:
            day["out_msg"] += 1
    elif kind == "reasoning":
        day["reasoning"] += 1
        _add_tokens(day["run"], step, state["run_model"].get(str(rid), "?"))


def _ingest_ledger(state: dict, line: bytes) -> None:
    """Fold one bin/llm ledger line into the state. A cost counts even on a
    line without tokens, as it does for bin/llm's spend limit."""
    state["ledger_rows"] += 1
    parsed = _parse_row(line)
    if parsed is None:
        state["ledger_skipped"] += 1
        return
    rec, day_key = parsed
    day = _day(state, day_key)
    model = str(rec.get("model") or "?")
    if not _add_tokens(day["llm"], rec, model):
        state["ledger_skipped"] += 1
    cost = rec.get("cost")
    if isinstance(cost, (int, float)) and not isinstance(cost, bool):
        day["cost"]["opencode" if rec.get("source") == "opencode" else "llm"] += cost
        day["cost"]["priced"] += 1
        per_model = day["llm"]["models"][model]
        per_model["cost"] = per_model.get("cost", 0.0) + cost


def _read_appended(path: Path, offset: int, ingest) -> int:
    """Feed every complete line past ``offset`` to ``ingest``; return the new
    offset. A trailing row without its newline is still being written and is
    picked up next time."""
    try:
        size = path.stat().st_size
    except OSError:
        return offset
    if size <= offset:
        return offset
    pos = offset
    with path.open("rb") as fh:
        fh.seek(offset)
        for raw in fh:
            if not raw.endswith(b"\n"):
                break
            pos += len(raw)
            line = raw.strip()
            if line:
                ingest(line)
    return pos


def _size(path: Path | None) -> int:
    if path is None:
        return 0
    try:
        return path.stat().st_size
    except OSError:
        return 0


def refresh(traj_dir: Path, identity_name: str, ledger: Path | None = None,
            rebuild: bool = False) -> dict:
    """Bring the cache up to date with the log (and ledger, when given) and
    return the new state. Reads only what was appended since the cached
    offsets; a file that shrank (rewritten, rotated) or a cache from another
    version triggers a full pass. The caller is responsible for the lock."""
    log = traj_dir / "trajectory.jsonl"
    state = None if rebuild else load(traj_dir)
    if state is None or state.get("identity") != identity_name:
        state = _empty_state(identity_name)
    if (_size(log) < int(state.get("log_offset") or 0)
            or _size(ledger) < int(state.get("ledger_offset") or 0)):
        state = _empty_state(identity_name)
    state["log_offset"] = _read_appended(
        log, int(state.get("log_offset") or 0),
        lambda line: _ingest_log(state, line, identity_name))
    if ledger is not None:
        state["ledger_offset"] = _read_appended(
            ledger, int(state.get("ledger_offset") or 0),
            lambda line: _ingest_ledger(state, line))
    state["generated"] = _now_iso()
    _write(traj_dir, state)
    return state


def start_refresh(traj_dir: Path, identity_name: str, ledger: Path | None = None,
                  rebuild: bool = False) -> bool:
    """Run refresh() on a background thread behind the .lock directory.
    Returns False (and does nothing) when a refresh is already running. A
    refresh that fails leaves the previous cache in place (the new state is
    written only at the end)."""
    if is_refreshing(traj_dir):
        return False
    lock = lock_path(traj_dir)
    lock.parent.mkdir(parents=True, exist_ok=True)
    try:
        lock.mkdir()
    except FileExistsError:
        return False

    def _run() -> None:
        try:
            refresh(traj_dir, identity_name, ledger=ledger, rebuild=rebuild)
        finally:
            shutil.rmtree(lock, ignore_errors=True)

    threading.Thread(target=_run, name="usage-refresh", daemon=True).start()
    return True


def _pending_bytes(traj_dir: Path, ledger: Path | None, state: dict | None) -> int:
    state = state or {}
    pending = _size(traj_dir / "trajectory.jsonl") - int(state.get("log_offset") or 0)
    pending += _size(ledger) - int(state.get("ledger_offset") or 0)
    return max(0, pending)


def _usd(value: float) -> float:
    """Round away float noise (0.1 + 0.2); a call can cost $0.00001."""
    return round(value, 8)


def _merge_day(day: dict) -> tuple[dict, dict]:
    """One API day: counters plus the tokens of the winning source, and that
    source's per-model map; cost is the ledger's either way."""
    llm_calls, run_calls = day["llm"]["calls"], day["run"]["calls"]
    source = "ledger" if llm_calls > 0 and llm_calls >= run_calls else "mindlog"
    tokens = day["llm"] if source == "ledger" else day["run"]
    out = {key: day.get(key, 0) for key in COUNT_KEYS}
    out.update({key: tokens[key] for key in TOKEN_KEYS})
    out["cost_llm"] = _usd(day["cost"]["llm"])
    out["cost_opencode"] = _usd(day["cost"]["opencode"])
    out["source"] = source
    return out, tokens["models"]


def summary(traj_dir: Path, identity_id: str, identity_name: str,
            ledger: Path | None = None) -> dict:
    """The API payload: cached series (if any) plus freshness signals."""
    state = load(traj_dir)
    base = {
        "identity": {"id": identity_id, "name": identity_name},
        "refreshing": is_refreshing(traj_dir),
        "pending_bytes": _pending_bytes(traj_dir, ledger, state),
    }
    if state is None or not state.get("generated"):
        return {**base, "available": False}
    daily = state.get("daily") or {}
    days = []
    by_model: dict[str, dict] = {}
    totals = {"in": 0, "out": 0, "think": 0, "calls": 0, "in_msg": 0, "out_msg": 0, "runs": 0}
    cost = {"cost_llm": 0.0, "cost_opencode": 0.0}
    ledger_calls = ledger_priced = 0
    ledger_since = None
    for day_key in sorted(daily):
        merged, models = _merge_day(daily[day_key])
        days.append([day_key, merged])
        for key in totals:
            totals[key] += int(merged.get(key, 0))
        for key in cost:
            cost[key] += merged[key]
        for model, counters in models.items():
            bucket = by_model.setdefault(model, {**dict.fromkeys(TOKEN_KEYS, 0), "cost": 0.0})
            for key in TOKEN_KEYS:
                bucket[key] += int(counters.get(key, 0))
        for model, counters in daily[day_key]["llm"]["models"].items():
            bucket = by_model.setdefault(model, {**dict.fromkeys(TOKEN_KEYS, 0), "cost": 0.0})
            bucket["cost"] += counters.get("cost", 0.0)
        ledger_calls += daily[day_key]["llm"]["calls"]
        ledger_priced += daily[day_key]["cost"]["priced"]
        if merged["source"] == "ledger" and ledger_since is None:
            ledger_since = day_key
    for bucket in by_model.values():
        bucket["cost"] = _usd(bucket["cost"])
    return {
        **base,
        "available": True,
        "generated": state["generated"],
        "rows": state.get("rows", 0),
        "skipped": state.get("skipped", 0),
        "ledger": {
            "rows": state.get("ledger_rows", 0),
            "skipped": state.get("ledger_skipped", 0),
            "since": ledger_since,
            "calls": ledger_calls,
            "priced": ledger_priced,
        },
        "daily": days,
        "by_model": {m: c for m, c in by_model.items() if c["calls"] > 0},
        "totals": {**totals, **{key: _usd(value) for key, value in cost.items()}},
    }
