#!/usr/bin/env python3
"""Durable, deterministic Signal reminders for Custos.

Scheduling resolves a Signal contact immediately and stores one immutable payload
with an absolute UTC deadline. A systemd timer calls ``dispatch`` every minute.
Every delivery attempt uses the same custos-actions request ID, so replay after a
crash or timeout cannot create a second Signal message.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


MAX_INPUT = 16384
MAX_MESSAGE = 12000
ACTIONS = os.environ.get("CUSTOS_ACTIONS", "custos-actions")
MEMORY = os.environ.get("CUSTOS_MEMORY", "custos-memory")
PARK_GRACE = 900  # seconds past the deadline before a parked goal is rechecked anyway


class ReminderError(ValueError):
    pass


def state_path():
    configured = os.environ.get("CUSTOS_REMINDERS_STATE")
    if configured:
        return Path(configured)
    identity = os.environ.get("IDENTITY_DIR")
    if not identity:
        raise ReminderError("IDENTITY_DIR is required")
    return Path(identity) / ".state" / "reminders.sqlite"


def connect(path=None):
    path = Path(path or state_path())
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path, timeout=20)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA busy_timeout=20000")
    db.execute("""CREATE TABLE IF NOT EXISTS reminders (
        id TEXT PRIMARY KEY,
        due REAL NOT NULL,
        local_at TEXT NOT NULL,
        timezone TEXT,
        target TEXT NOT NULL,
        target_label TEXT NOT NULL,
        message TEXT NOT NULL,
        goal_id TEXT,
        request_id TEXT NOT NULL UNIQUE,
        phase TEXT NOT NULL,
        created REAL NOT NULL,
        updated REAL NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_result TEXT
    )""")
    db.commit()
    return db


def parse_due(value, zone_name=None, now=None):
    if not isinstance(value, str) or not value.strip() or len(value) > 80:
        raise ReminderError("at must be an ISO date/time")
    raw = value.strip().replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError as exc:
        raise ReminderError("at must be an ISO date/time") from exc
    if parsed.tzinfo is None:
        if not isinstance(zone_name, str) or not zone_name:
            raise ReminderError("a local at value requires timezone, for example America/Denver")
        try:
            zone = ZoneInfo(zone_name)
        except ZoneInfoNotFoundError as exc:
            raise ReminderError("unknown timezone") from exc
        candidates = {}
        for fold in (0, 1):
            aware = parsed.replace(tzinfo=zone, fold=fold)
            utc = aware.astimezone(timezone.utc)
            if utc.astimezone(zone).replace(tzinfo=None) == parsed:
                candidates[utc.timestamp()] = aware
        if not candidates:
            raise ReminderError("local time does not exist in that timezone")
        if len(candidates) != 1:
            raise ReminderError("local time is ambiguous; supply an ISO timestamp with an explicit UTC offset")
        aware = next(iter(candidates.values()))
    else:
        if zone_name is not None:
            raise ReminderError("timezone is only used with a local at value")
        aware = parsed
    due = aware.astimezone(timezone.utc)
    current = now or datetime.now(timezone.utc)
    if due <= current:
        raise ReminderError("reminder time must be in the future")
    if (due - current).total_seconds() > 2 * 366 * 86400:
        raise ReminderError("reminder time is more than two years away")
    return due, aware.isoformat()


def actions_call(arguments, payload=None, timeout=50):
    process = subprocess.run([ACTIONS, *arguments],
                             input=(json.dumps(payload, ensure_ascii=False) if payload is not None else None),
                             text=True, capture_output=True, timeout=timeout, check=False)
    try:
        result = json.loads(process.stdout)
    except (ValueError, TypeError):
        result = {"ok": False, "error": (process.stderr or process.stdout or "invalid actions response")[:300]}
    return process.returncode, result


def memory_call(arguments, payload, timeout=30):
    """Best-effort native goal bookkeeping through custos-memory. A failure here never
    fails a reminder: the reminder is the durable thing, the goal state is a courtesy."""
    try:
        process = subprocess.run([MEMORY, *arguments], input=json.dumps(payload, ensure_ascii=False),
                                 text=True, capture_output=True, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        return False, type(exc).__name__
    if process.returncode:
        return False, (process.stderr or process.stdout or "custos-memory failed")[:300]
    return True, (process.stdout or "")[:300]


def park_goal(goal_id, reminder_id, local_at, due):
    """A scheduled reminder needs no wake until its receipt, so park the linked goal as
    waiting: QUICK/OVERDUE routing then stops re-verifying it (2026-09-18: three wakes
    re-checked one parked reminder). The wait ends on the person's reply, on the
    dispatcher's resume at submission, or PARK_GRACE after the deadline as a fallback."""
    check_at = datetime.fromtimestamp(due.timestamp() + PARK_GRACE, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    ok, detail = memory_call(["wait"], {"goal_id": goal_id, "check_at": check_at,
        "reason": "Reminder " + reminder_id + " is scheduled for " + local_at
                  + "; delivery is deterministic (custos-reminders dispatch), nothing to verify until its receipt"})
    return {"ok": ok, "detail": detail}


def resume_goal(row, phase, result, stamp):
    """Signal accepted the reminder: wake the parked goal once with the receipt so the
    next wake can complete it. A goal that is not waiting is left alone."""
    if phase != "submitted" or row["phase"] == "submitted" or not row["goal_id"]:
        return
    when = datetime.fromtimestamp(stamp, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    memory_call(["resume"], {"goal_id": row["goal_id"],
        "evidence": "Reminder " + row["id"] + " submitted to " + row["target_label"] + " at " + when
                    + " (request " + row["request_id"] + "); read custos-reminders status " + row["id"]
                    + " for the receipt, then complete the goal"})


def resolve_target(label):
    if not isinstance(label, str) or not label.strip() or len(label) > 128:
        raise ReminderError("target must be a Signal contact label")
    code, result = actions_call(["signal-contacts"])
    if code or not result.get("ok", True):
        raise ReminderError("Signal contacts are unavailable")
    rows = result.get("destinations") or result.get("contacts") or (result if isinstance(result, list) else [])
    matches = [row for row in rows if isinstance(row, dict)
               and str(row.get("label", "")).casefold() == label.strip().casefold()
               and isinstance(row.get("target"), str)]
    if len(matches) != 1:
        raise ReminderError("target is not uniquely allowlisted")
    return matches[0]["target"], matches[0].get("label") or label.strip()


def schedule(payload, path=None, now=None):
    if not isinstance(payload, dict) or set(payload) - {"at", "timezone", "target", "message", "goal_id"}:
        raise ReminderError("schedule needs only at, timezone, target, message and optional goal_id")
    if not {"at", "target", "message"} <= set(payload):
        raise ReminderError("schedule needs at, target and message")
    message = payload["message"]
    if not isinstance(message, str) or not message.strip() or len(message.encode()) > MAX_MESSAGE:
        raise ReminderError("message must be nonempty and at most 12000 UTF-8 bytes")
    goal_id = payload.get("goal_id")
    if goal_id is not None and (not isinstance(goal_id, str) or not re.fullmatch(r"[0-9a-f]{8}", goal_id)):
        raise ReminderError("goal_id must be a native eight-hex ID")
    due, local_at = parse_due(payload["at"], payload.get("timezone"), now=now)
    target, target_label = resolve_target(payload["target"])
    canonical = json.dumps({"due": due.timestamp(), "target": target, "message": message,
                            "goal_id": goal_id}, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    digest = hashlib.sha256(canonical.encode()).hexdigest()
    reminder_id = digest[:16]
    request_id = "reminder-" + digest[:32]
    created = (now or datetime.now(timezone.utc)).timestamp()
    db = connect(path)
    try:
        with db:
            existing = db.execute("SELECT * FROM reminders WHERE id=?", (reminder_id,)).fetchone()
            if existing:
                return public(existing, created=False)
            db.execute("""INSERT INTO reminders
                (id,due,local_at,timezone,target,target_label,message,goal_id,request_id,phase,created,updated)
                VALUES (?,?,?,?,?,?,?,?,?,'pending',?,?)""",
                (reminder_id, due.timestamp(), local_at, payload.get("timezone"), target, target_label,
                 message, goal_id, request_id, created, created))
            row = db.execute("SELECT * FROM reminders WHERE id=?", (reminder_id,)).fetchone()
        result = public(row, created=True)
        if goal_id:
            result["parked"] = park_goal(goal_id, reminder_id, local_at, due)
        return result
    finally:
        db.close()


def public(row, created=None):
    result = {key: row[key] for key in ("id", "local_at", "timezone", "target_label", "message",
                                         "goal_id", "request_id", "phase", "attempts")}
    result["due_utc"] = datetime.fromtimestamp(row["due"], timezone.utc).isoformat()
    if created is not None:
        result["created"] = created
    if row["last_result"]:
        try:
            result["last_result"] = json.loads(row["last_result"])
        except ValueError:
            result["last_result"] = row["last_result"]
    return result


def set_result(db, row, phase, result, attempted=False, now=None):
    stamp = now if now is not None else time.time()
    db.execute("UPDATE reminders SET phase=?,updated=?,attempts=attempts+?,last_result=? WHERE id=?",
               (phase, stamp, 1 if attempted else 0,
                json.dumps(result, sort_keys=True, ensure_ascii=False)[:8000], row["id"]))


def phase_from(result):
    phase = result.get("phase") if isinstance(result, dict) else None
    return phase if phase in {"queued", "submitted", "uncertain", "blocked"} else None


def dispatch(path=None, now=None, limit=16):
    stamp = now if now is not None else time.time()
    db = connect(path)
    report = {"due": 0, "submitted": 0, "queued": 0, "uncertain": 0, "blocked": 0, "retry": 0}
    try:
        rows = db.execute("""SELECT * FROM reminders
            WHERE (phase IN ('pending','retry','uncertain') AND due<=?) OR phase='queued'
            ORDER BY due,id LIMIT ?""", (stamp, limit)).fetchall()
        for row in rows:
            if row["due"] <= stamp:
                report["due"] += 1
            code, status = actions_call(["status", row["request_id"]])
            known = phase_from(status) if code == 0 and status.get("ok") else None
            if known:
                with db:
                    set_result(db, row, known, status, now=stamp)
                resume_goal(row, known, status, stamp)
                report[known] += 1
                continue
            if row["phase"] == "queued":
                report["queued"] += 1
                continue
            payload = {"request_id": row["request_id"], "target": row["target"], "message": row["message"]}
            if row["goal_id"]:
                # Preserve explicitly requested kitchen timers through the send-time consent guard.
                # Correlation comes from the existing native request, never invented by the scheduler.
                from custos_memory import Store
                try:
                    origin = Store().find(row["goal_id"])[4]["origin"]
                    if origin.get("authority") == "operator" and origin["request_id"].startswith("signal:"):
                        payload["reply_to"] = origin["request_id"]
                except (OSError, KeyError, TypeError, RuntimeError): pass
            try:
                code, result = actions_call(["signal-send"], payload)
            except (OSError, subprocess.SubprocessError) as exc:
                code, result = 2, {"ok": False, "error": type(exc).__name__}
            phase = phase_from(result) if code == 0 and result.get("ok") else "retry"
            with db:
                set_result(db, row, phase, result, attempted=True, now=stamp)
            resume_goal(row, phase, result, stamp)
            report[phase] += 1
        return report
    finally:
        db.close()


def list_reminders(path=None):
    db = connect(path)
    try:
        return [public(row) for row in db.execute("SELECT * FROM reminders ORDER BY due,id")]
    finally:
        db.close()


def cancel(reminder_id, path=None):
    if not re.fullmatch(r"[0-9a-f]{16}", reminder_id or ""):
        raise ReminderError("reminder ID must be 16 hex characters")
    db = connect(path)
    try:
        with db:
            row = db.execute("SELECT * FROM reminders WHERE id=?", (reminder_id,)).fetchone()
            if not row:
                raise ReminderError("unknown reminder")
            if row["phase"] not in {"pending", "retry"}:
                raise ReminderError("reminder was already handed to the Signal delivery broker")
            db.execute("UPDATE reminders SET phase='cancelled',updated=? WHERE id=?", (time.time(), reminder_id))
            return public(db.execute("SELECT * FROM reminders WHERE id=?", (reminder_id,)).fetchone())
    finally:
        db.close()


def read_payload():
    raw = sys.stdin.buffer.read(MAX_INPUT + 1)
    if len(raw) > MAX_INPUT:
        raise ReminderError("request too large")
    try:
        return json.loads(raw)
    except ValueError as exc:
        raise ReminderError("schedule expects one JSON object on stdin") from exc


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["schedule", "dispatch", "list", "status", "cancel"])
    parser.add_argument("reminder_id", nargs="?")
    args = parser.parse_args()
    try:
        if args.command == "schedule":
            if args.reminder_id:
                raise ReminderError("schedule takes JSON on stdin, not a reminder ID")
            result = schedule(read_payload())
        elif args.command == "dispatch":
            if args.reminder_id:
                raise ReminderError("dispatch takes no reminder ID")
            result = dispatch()
        elif args.command == "list":
            if args.reminder_id:
                raise ReminderError("list takes no reminder ID")
            result = list_reminders()
        elif args.command == "status":
            rows = [row for row in list_reminders() if row["id"] == args.reminder_id]
            if len(rows) != 1:
                raise ReminderError("unknown reminder")
            result = rows[0]
        else:
            if not args.reminder_id:
                raise ReminderError("cancel requires a reminder ID")
            result = cancel(args.reminder_id)
        print(json.dumps({"ok": True, "result": result}, ensure_ascii=False, sort_keys=True))
        return 0
    except ReminderError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        return 2


if __name__ == "__main__":
    sys.exit(main())
