"""Bounded observation, durable intake before acknowledgement, no model calls."""
import argparse
from datetime import datetime, timedelta, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import urllib.error
import uuid
import xml.etree.ElementTree as ET

from custos_square import APIError, ORIGIN, STATE, SECRET, Square, Store, allowance_summary, canonical, digest, note_allowance, public_request, square_queue, read_native_line, MAX_AGE_HOURS
import custos_square_policy as square_policy

# Outbox drain bounds per pass (see Observer._drain_outbox).
DRAIN_SECONDS = float(os.environ.get("CUSTOS_OUTBOX_DRAIN_SECONDS", "20"))
DRAIN_MAX_BYTES = 64 * 1024 * 1024

BUCKETS = ("replies", "comments_on_your_posts", "mentions_of_you", "in_threads_you_joined")
CONFIG = Path("/var/lib/custos/config/observations.json")
if not CONFIG.exists():
    CONFIG = Path(__file__).with_name("observations.json")


def square_sender(author, post, comment=0):
    if not isinstance(author, str) or not re.fullmatch(r"[A-Za-z0-9_-]{2,32}", author):
        raise APIError("inbox_author_contract")
    if type(post) is not int or post < 1 or type(comment) is not int or comment < 0:
        raise APIError("inbox_target_contract")
    return "square:" + author + ":" + str(post) + ":" + str(comment)


class Native:
    def __init__(self, store):
        self.store = store
        self.root = os.environ.get("ROOT_TRAJ_ID") or os.environ.get("TRAJ_ID")
        result = subprocess.run(["traj", "path", self.root], check=True, capture_output=True, text=True, timeout=20)
        self.path = Path(result.stdout.strip())
        if not self.path.is_file():
            raise APIError("native_root_missing")

    def capture(self, payload, deferred=False):
        if deferred:
            from custos_memory import Store as NativeStore
            return NativeStore().capture(payload, deferred=True)
        result = subprocess.run(["custos-memory", "capture"], input=canonical(payload), text=True, capture_output=True, timeout=45)
        if result.returncode:
            raise APIError("native_capture_failed")
        data = json.loads(result.stdout)
        if not data.get("goal_id") or data.get("request_id") != payload["request_id"]:
            raise APIError("native_capture_receipt_invalid")
        return data

    def append(self, identity, envelope):
        key = "native:" + identity
        state = self.store.get(key)
        if state and state.get("done"):
            return state["step_id"]
        if state is None:
            state = {"offset": self.path.stat().st_size, "step_id": str(uuid.uuid4())}
            self.store.put(key, state)
        # Only scan the suffix since the pending append, not the entire trajectory.
        with self.path.open("rb") as source:
            source.seek(state["offset"])
            found = any(json.loads(line).get("step_id") == state["step_id"] for line in source if line.endswith(b"\n"))
        if not found:
            row = dict(envelope, step_id=state["step_id"])
            result = subprocess.run(["traj", "append", self.root], input=canonical(row), text=True, capture_output=True, timeout=30)
            if result.returncode:
                raise APIError("native_append_failed")
        with self.path.open("rb") as source:
            os.fsync(source.fileno())
        state["done"] = True
        self.store.put(key, state)
        return state["step_id"]


def self_metrics(path, now=None, hours=24, me="custos"):
    """Custos's own numbers for the last `hours`, from the root trajectory:
    observed starts and ends, durable logging markers, and what reached people.
    A living benchmark it can read about itself (independent evaluation,
    2026-09-09) instead of waiting for a human audit."""
    now = time.time() if now is None else now
    since = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now - hours * 3600))
    runs = {}
    reasoning = []
    responder = {"replied": 0, "no-reply": 0, "deferred": 0, "failed": 0}
    composed = delivered = signal_out = social_msgs = opened = closed = 0
    durable_types = ("thought", "observation", "message", "idle", "final")
    with open(path, "rb") as f:
        for line in f:
            if b'"ts"' not in line:
                continue
            try:
                s = json.loads(line)
            except ValueError:
                continue
            ts = s.get("ts", "")
            t = s.get("type")
            if t == "shellm-run" and ts >= since:
                runs[s["step_id"]] = {
                    "by": s.get("launched_by", "?"), "n": 0, "llm": 0.0,
                    "first_durable": None, "has_final": False,
                    "has_other_durable": False, "ended": False, "rc": None,
                }
                continue
            rid = s.get("run_id")
            r = runs.get(rid)
            if t == "reasoning" and r is not None:
                r["n"] += 1
                r["llm"] += float(s.get("llm_s") or 0)
                reasoning.append(((s.get("thought") or ""), (s.get("cmd") or ""), r["by"]))
            elif t in durable_types and r is not None:
                if r["first_durable"] is None:
                    r["first_durable"] = r["n"]
                if t == "final":
                    r["has_final"] = True
                else:
                    r["has_other_durable"] = True
            elif t == "run-end" and r is not None:
                # An end record is observable independently of whether it has a
                # usable return code. Missing and non-integer codes remain unknown.
                r["ended"] = True
                r["rc"] = s.get("rc")
            if ts < since:
                continue
            if t == "observation" and s.get("source") == "responder" and s.get("decision"):
                d = s["decision"]
                if s.get("deferred"):
                    responder["deferred"] += 1
                if d in ("replied", "sent"):
                    responder["replied"] += 1
                elif d == "no-reply":
                    responder["no-reply"] += 1
                elif "fail" in d:
                    responder["failed"] += 1
            if t == "observation" and s.get("source") == "square-outbox" and "Public square reply delivered" in (s.get("content") or ""):
                delivered += 1
            if t == "message" and s.get("from") == me:
                to = str(s.get("to", ""))
                if to.startswith("square:"):
                    composed += 1
                elif to.startswith("signal"):
                    signal_out += 1
                    if r is not None and r["by"] == "social":
                        social_msgs += 1
            if t == "observation" and s.get("source") == "responder" and s.get("deferred"):
                opened += 1
            if str(s.get("request_id", "")).startswith("custos-resolve:"):
                closed += 1
    mono = [r for r in runs.values() if r["by"] == "monolith"]
    mono_completed = [r for r in mono if r["ended"]]
    mono_known_rc = [r for r in mono_completed if type(r["rc"]) is int]

    def pct(a, b):
        return int(round(100.0 * a / b)) if b else 0

    def p(values, q):
        values = sorted(values)
        return values[min(len(values) - 1, int(q * len(values)))] if values else 0

    mono_reason = [x for x in reasoning if x[2] == "monolith"]
    trunc = sum(1 for th, cmd, _ in mono_reason if re.search(r"truncat|archaeolog|re-?read|lost (the )?(output|middle)", th, re.I))
    selfread = sum(1 for th, cmd, _ in mono_reason if re.search(r"\btraj (show|tail|search|grep)\b", cmd))
    cap = int(os.environ.get("SHELLM_MAX_ITERATIONS", "150") or 150)
    metrics = {
        "metrics_schema_version": 2,
        "window_hours": hours, "at": time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime(now)),
        # Starts, observed end records, and observed end records without a
        # usable code are distinct facts; open means no end was observed.
        "monolith_wakes": len(mono),
        "monolith_completed_wakes": len(mono_completed),
        "monolith_open_wakes": len(mono) - len(mono_completed),
        "monolith_known_rc_wakes": len(mono_known_rc),
        "monolith_unknown_rc_wakes": len(mono_completed) - len(mono_known_rc),
        "monolith_rc_nonzero_pct": pct(sum(1 for r in mono_known_rc if r["rc"] != 0), len(mono_known_rc)),
        # These describe only runs for which a run-end was observed.
        "monolith_iterations_p50": p([r["n"] for r in mono_completed], 0.5),
        "monolith_iterations_p90": p([r["n"] for r in mono_completed], 0.9),
        "monolith_first_durable_p50": p([r["first_durable"] for r in mono_completed if r["first_durable"] is not None], 0.5),
        "monolith_no_durable_step": sum(1 for r in mono_completed if r["first_durable"] is None),
        "monolith_at_cap": sum(1 for r in mono_completed if r["n"] >= cap),
        # A final is a marker, not an outcome: final-only has no other marker.
        "monolith_completed_final_only_wakes": sum(
            1 for r in mono_completed if r["has_final"] and not r["has_other_durable"]
        ),
        "monolith_completed_other_durable_wakes": sum(
            1 for r in mono_completed if r["has_other_durable"]
        ),
        "truncation_thought_pct": pct(trunc, len(mono_reason)), "self_read_cmd_pct": pct(selfread, len(mono_reason)),
        "inference_hours": round(sum(r["llm"] for r in runs.values()) / 3600, 2),
        "inference_hours_monolith": round(sum(r["llm"] for r in mono) / 3600, 2),
        "social_runs": sum(1 for r in runs.values() if r["by"] == "social"),
        "square_composed": composed, "square_delivered": delivered,
        "signal_sent": signal_out, "signal_sent_by_social": social_msgs,
        "responder": responder, "goals_opened": opened, "goals_closed": closed,
    }
    return metrics


def metrics_text(m, previous=None):
    def delta(key):
        if not previous or key not in previous:
            return ""
        d = m[key] - previous[key]
        return " (%s%d)" % ("+" if d >= 0 else "", d)

    line = (
        "Daily self-metrics, last %d h: %d monolith wakes%s (observed starts), %d ended wakes, "
        "%d wakes with no run-end observed; %d ended wakes with known rc / %d with unknown rc, "
        "%d%% nonzero among known-rc ended wakes; completed-wake iterations p50 %d / p90 %d, "
        "first durable logging marker at p50 %d, %d completed wakes with no durable logging marker, "
        "%d completed wakes at the iteration cap, %d completed final-only wakes / %d with other durable markers; "
        "%d%% of thoughts about lost or re-read context, %d%% of commands traj self-reads; inference %.1f h "
        "(monolith %.1f h); square %d composed / %d delivered%s; Signal %d sent (%d by the social thinker "
        "in %d social runs); responder %d replied / %d quiet / %d deferred / %d failed; goals %d opened / %d closed."
        % (
            m["window_hours"], m["monolith_wakes"], delta("monolith_wakes"),
            m["monolith_completed_wakes"], m["monolith_open_wakes"],
            m["monolith_known_rc_wakes"], m["monolith_unknown_rc_wakes"],
            m["monolith_rc_nonzero_pct"], m["monolith_iterations_p50"],
            m["monolith_iterations_p90"], m["monolith_first_durable_p50"],
            m["monolith_no_durable_step"], m["monolith_at_cap"],
            m["monolith_completed_final_only_wakes"],
            m["monolith_completed_other_durable_wakes"],
            m["truncation_thought_pct"], m["self_read_cmd_pct"],
            m["inference_hours"], m["inference_hours_monolith"],
            m["square_composed"], m["square_delivered"], delta("square_delivered"),
            m["signal_sent"], m["signal_sent_by_social"], m["social_runs"],
            m["responder"]["replied"], m["responder"]["no-reply"],
            m["responder"]["deferred"], m["responder"]["failed"],
            m["goals_opened"], m["goals_closed"],
        )
    )
    line += (
        " These are observations, not a verdict: marker latency and the absence of a durable "
        "logging marker describe logging, not work start or value; a final is a logging marker, "
        "not proof of success. A composed reply is not a delivered one."
    )
    return line

HOUSEKEEPING_TMP = Path("/tmp")
HOUSEKEEPING_JOBS = Path("/var/lib/custos-harness/jobs")


HOUSEKEEPING_CLONES = Path("/opt/custos/work/repos")


def housekeep(now, tmp=HOUSEKEEPING_TMP, jobs=HOUSEKEEPING_JOBS, logs=None,
              clone_age=48 * 3600, job_age=7 * 86400, log_bytes=512 << 20,
              settled=(), clones=HOUSEKEEPING_CLONES):
    """Reclaim the disk the mind's own scratch leaves behind, touching nothing young and
    nothing that is not obviously scratch (2026-09-17: 5 GB gone in nine hours; /tmp held
    4.7 GB of PR checkouts, 446 sealed job sandboxes held 2 GB, monolith.log was 1.5 GB).
    Only git checkouts and subrun reports under tmp, sealed job directories older than a
    week, and oversized run logs are handled. Logs rotate copy-truncate style: the
    thinkers append with `tee -a`, so a truncated file keeps receiving new lines and the
    previous contents survive once as NAME.log.1."""
    import gzip, shutil, subprocess
    report = {"at": now, "removed": [], "rotated": [], "compressed": [], "bytes": 0}
    def size(path):
        try:
            return sum(f.stat().st_size for f in path.rglob("*") if f.is_file()) if path.is_dir() else path.stat().st_size
        except OSError:
            return 0

    def stale(path, age):
        try:
            latest = max([path.stat().st_mtime] + [c.stat().st_mtime for c in path.iterdir()] if path.is_dir() else [path.stat().st_mtime])
        except OSError:
            return False
        return now - latest > age

    for child in sorted(tmp.iterdir()) if tmp.is_dir() else []:
        try:
            is_clone = child.is_dir() and not child.is_symlink() and (child / ".git").exists()
            is_report = child.is_file() and child.name.startswith("subrun-") and child.suffix == ".txt"
            if is_report and stale(child, job_age):
                report["bytes"] += size(child)
                shutil.rmtree(child) if child.is_dir() else child.unlink()
                report["removed"].append(str(child))
        except OSError:
            continue
    for child in sorted(jobs.iterdir()) if jobs.is_dir() else []:
        try:
            if child.is_dir() and not child.is_symlink() and stale(child, job_age):
                report["bytes"] += size(child)
                shutil.rmtree(child)
                report["removed"].append(str(child))
        except OSError:
            continue
    # Removed worktrees leave stale registrations in the clone they belong to.
    if report["removed"] and clones and clones.is_dir():
        for repo in sorted(p for p in clones.glob("*/*") if (p / ".git").exists()):
            try:
                subprocess.run(["git", "-C", str(repo), "worktree", "prune"], capture_output=True, timeout=30, check=False)
            except (OSError, subprocess.SubprocessError):
                continue

    # The rotated copy is gzipped (level 1: a 1.5 GB monolith.log.1 sat uncompressed on
    # disk for a day, 2026-09-18); a leftover plain NAME.log.1 from the earlier scheme is
    # compressed on the next pass.
    def compress(source, target):
        with open(source, "rb") as src, gzip.open(target, "wb", compresslevel=1) as dst:
            shutil.copyfileobj(src, dst)

    for log in sorted(logs.glob("*.log")) if logs and logs.is_dir() else []:
        try:
            if log.is_file() and log.stat().st_size > log_bytes:
                previous = log.with_name(log.name + ".1.gz")
                report["bytes"] += size(previous) if previous.exists() else 0
                compress(log, previous)
                with open(log, "r+b") as handle:
                    handle.truncate(0)
                report["rotated"].append(str(log))
        except OSError:
            continue
    for leftover in sorted(logs.glob("*.log.1")) if logs and logs.is_dir() else []:
        try:
            if leftover.is_file():
                compress(leftover, leftover.with_name(leftover.name + ".gz"))
                report["bytes"] += size(leftover)
                leftover.unlink()
                report["compressed"].append(str(leftover))
        except OSError:
            continue
    return report


class Observer:
    def __init__(self, config, store, square, native, now=None):
        self.config, self.store, self.square, self.native = config, store, square, native
        self.now = time.time() if now is None else now
        self.remaining = min(12, max(1, int(config.get("max_signals_per_run", 6))))

    def emit(self, identity, content, source_url="", **fields):
        if self.store.seen(identity):
            return True
        if self.remaining <= 0:
            return False
        envelope = {"type": "observation", "source": "custos-observe", "content": SECRET.sub("[redacted credential]", content), "source_url": source_url, "authority": "external", **fields}
        self.native.append(identity, envelope)
        self.store.disposition(identity, "emitted", envelope)
        self.remaining -= 1
        return True

    def source(self, name, interval, function):
        state = self.store.get("source:" + name, {})
        if self.now < state.get("next", 0):
            return
        try:
            function()
        except (APIError, OSError, ValueError, KeyError, TypeError, ET.ParseError, subprocess.SubprocessError) as exc:
            code = exc.code if isinstance(exc, APIError) else type(exc).__name__
            if code in ('square_pacing_deferred', 'platform_allowance_exhausted'):
                # Normal backpressure is not an outage and must not wake the mind.
                self.store.put('source:' + name, {'next': self.now + max(60, exc.retry_after),
                                                'deferred': code, 'last_success': state.get('last_success')})
                return
            failures = state.get("failures", 0) + 1
            episode = state.get("episode", 0) + (0 if state.get("error") else 1)
            if not state.get("error") or not state.get("alerted"):
                alerted = self.emit("failure:" + name + ":" + str(episode), "Observation source unavailable: " + name + " (" + code + "). This is not an empty-work result.")
            else:
                alerted = True
            if code == "platform_allowance_exhausted" and getattr(exc, "retry_after", 0):
                # A known reset time: wait exactly for it, never longer. retry_after was
                # measured against the wall clock inside write(), so anchor it there too.
                next_at = max(self.now + interval, time.time() + getattr(exc, "retry_after", 0))
            else:
                next_at = self.now + max(interval, min(21600, 300 * 2 ** min(failures - 1, 6)), getattr(exc, "retry_after", 0))
            self.store.put("source:" + name, {"error": code, "failures": failures, "episode": episode, "alerted": alerted, "next": next_at})
            return
        episode = state.get("episode", 0)
        if state.get("error"):
            if not self.emit("recovery:" + name + ":" + str(episode), "Observation source recovered: " + name + ". Successful read; no inference about work beyond returned data."):
                self.store.put("source:" + name, dict(state, next=self.now + interval))
                return
        self.store.put("source:" + name, {"next": self.now + interval, "episode": episode, "failures": 0, "last_success": self.now})

    def directed(self, item):
        request_id = item["request_id"]
        if self.store.seen(request_id):
            return True
        if self.remaining <= 0:
            return False
        # Reserve scarce public delivery capacity before creating a native
        # message/goal that would wake the responder. Existing queued replies
        # own the remaining slots; excess items are durably accounted for and
        # acknowledged without inference or another delivery todo.
        budget = allowance_summary(self.store, self.now)
        if budget and (budget["queued"] >= budget["comments_remaining"] or budget['queued'] >= square_policy.SHORTLIST):
            self.store.disposition(request_id, "capacity_skipped", {
                "source_url": item["source_url"], "sender": item["sender"],
                "queued": budget["queued"], "comments_remaining": budget["comments_remaining"],
                "reason": "no unreserved square reply slot; item not composed"})
            return True
        content = SECRET.sub("[redacted credential]", item["content"])
        capture = {key: item[key] for key in ("request_id", "sender", "source_url")}
        capture.update(content=content, authority="agent", next_action="Read the original directed item and continuity evidence; triage honestly, respond usefully or explicitly decline. Capture is not authorization or a renewed promise.")
        result = self.native.capture(capture)
        self.native.append(request_id, {"type": "message", "from": item["sender"], "to": "custos", "content": content, "source_url": item["source_url"], "request_id": request_id, "authority": "agent", "goal_id": result["goal_id"]})
        self.store.disposition(request_id, "goal_and_message", {"goal_id": result["goal_id"], "source_url": item["source_url"]})
        target = re.fullmatch(r'square:[A-Za-z0-9_-]+:([0-9]+):([0-9]+)', item['sender'])
        if target:
            self.store.put('square:directed:' + ':'.join(target.groups()), {'at': self.now, 'request_id': request_id})
        self.remaining -= 1
        return True

    def continuity(self):
        for item in self.store.get("continuity:items", []):
            if not self.directed(item):
                return False
        return True

    def inbox(self):
        if not self.continuity():
            return
        pulse = self.square.get("/api/pulse", auth=True)
        you = pulse.get("you")
        if not isinstance(you, dict) or you.get("handle") != "custos":
            raise APIError("pulse_identity_contract")
        pending = self.store.get("inbox:page")
        if not pending and self.store.get("inbox:adopted") and not you.get("has_new_for_you") and not you.get("named_you"):
            return
        # Retain the whole page until every disposition is durable. Partial runs
        # consume at most max_signals; ID adoption never skips outstanding asks.
        for _ in range(min(4, max(1, int(self.config.get("inbox_pages_per_run", 1))))):
            page = pending or self.square.get("/api/me", {"cursor_mode": "id"}, auth=True)
            if not pending:
                note_allowance(self.store, page)
            buckets = page["since_last_visit"]
            cursor = page.get("ack_cursor")
            if page.get("cursor_mode") != "id" or buckets.get("contract") != "1f916.inbox.since_last_visit.v5":
                raise APIError("inbox_contract_changed")
            cursor_fields = {"version", "timestamp", "comments", "mentions"}
            if (not isinstance(cursor, dict) or not cursor_fields <= set(cursor)
                    or set(cursor) - cursor_fields - {"seal"} or cursor["version"] != 1
                    or any(type(cursor[k]) is not int or cursor[k] < 0 for k in cursor_fields)
                    or ("seal" in cursor and (not isinstance(cursor["seal"], str)
                        or not re.fullmatch(r"[A-Za-z0-9_-]{16,256}", cursor["seal"])))):
                raise APIError("invalid_ack_cursor")
            if any(not isinstance(buckets.get(bucket), list) or len(buckets[bucket]) > 50 for bucket in BUCKETS):
                raise APIError("inbox_bucket_contract")
            self.store.put("inbox:page", page)
            for bucket in BUCKETS:
                for item in buckets[bucket]:
                    post = item.get("post_id")
                    comment = item.get("comment_id", item.get("id"))
                    if type(post) is not int or post < 1 or (comment is not None and (type(comment) is not int or comment < 1)):
                        raise APIError("inbox_target_contract")
                    source_url = ORIGIN + "/api/" + ("comment/" + str(comment) if comment else "post/" + str(post))
                    request_id = "square:" + ("comment:" + str(comment) if comment else "post:" + str(post))
                    directed = bucket != "in_threads_you_joined" or bool(re.search(r"(?<![A-Za-z0-9_-])@custos(?![A-Za-z0-9_-])", item.get("body") or "", re.IGNORECASE))
                    disposition_id = "inbox:" + bucket + ":" + str(item.get("mention_id") or comment or post)
                    if self.store.seen(disposition_id):
                        continue
                    if directed and not self.store.seen(request_id):
                        if self.remaining <= 0:
                            return
                        author = item.get("author")
                        content = item.get("body") or item.get("post_title") or "Source is moderated/withdrawn; inspect source and explicitly dispose this directed request."
                        sender = square_sender(author, post, comment or 0)
                        self.directed({"request_id": request_id, "sender": sender, "source_url": source_url, "content": content})
                    self.store.disposition(disposition_id, "directed_accounted_for" if directed else "ambient_not_directed", item)
            # The exact server object, including mention-row ID, never recomputed.
            self.square.request("/api/me/ack", method="POST", body={"up_to": cursor}, auth=True)
            self.store.put("inbox:cursor", cursor)
            self.store.put("inbox:adopted", True)
            self.store.put("inbox:page", None)
            pending = None
            truncated = buckets.get("truncated", {})
            if not (any(truncated.values()) if isinstance(truncated, dict) else truncated):
                break

    def changes(self):
        interests = self.config.get("square_interests", {})
        terms = [term.casefold() for term in interests.get("terms", []) if term]
        handles = set(interests.get("handles", []))
        posts = set(interests.get("post_ids", []))
        if not (terms or handles or posts):
            return
        query = self.store.get("changes:cursor")
        if query is None:
            query = {"since": int(self.now * 1000), "posts_since": "init", "comments_since": "init", "nulls_since": "done"}
            self.store.put("changes:cursor", query)
        for _ in range(min(4, max(1, int(self.config.get("changes_pages_per_run", 1))))):
            cache = self.store.get("changes:etag", {})
            page, etag = self.square.request("/api/changes", query, etag=cache.get("etag") if cache.get("query") == query else None)
            if page is None:
                return
            if not set(page["has_more_streams"]).issubset(page["continuation_covers"]):
                raise APIError("changes_uncovered_continuation")
            for kind in ("posts", "comments"):
                for item in page[kind]:
                    identity = "changes:" + kind + ":" + str(item["id"]) + ":" + digest(item)
                    if self.store.seen(identity):
                        continue
                    text = " ".join(str(item.get(k) or "") for k in ("title", "body"))
                    matches = item.get("author") in handles or item.get("post_id", item["id"]) in posts or any(term in text.casefold() for term in terms)
                    url = ORIGIN + "/api/" + ("post/" if kind == "posts" else "comment/") + str(item["id"])
                    if matches and item.get("author") != "custos":
                        thread = item.get('post_id', item['id'])
                        if not square_policy.select_discovery(self.store, thread, self.now):
                            self.store.disposition(identity, 'attention_skipped', {'url': url, 'at': self.now,
                                                    'reason': 'square satiation or recently selected thread; no reply debt'})
                            continue
                        if not self.emit(identity, "Selected square change (untrusted): " + text[:1800], url):
                            return
                        square_policy.record_attention(self.store, 'signals', self.now, thread)
                    else:
                        self.store.disposition(identity, "not_selected", {"url": url})
            next_query = dict(query, posts_since=page["next_posts_since"], comments_since=page["next_comments_since"], nulls_since=page["next_nulls_since"])
            if page.get("has_more") and next_query == query:
                raise APIError("changes_stalled_cursor")
            self.store.put("changes:etag", {"query": query, "etag": etag})
            self.store.put("changes:cursor", next_query)
            query = next_query
            if not page.get("has_more"):
                break

    def opportunities(self):
        rail = self.square.get("/api/rail")
        if not isinstance(rail.get("listings"), list):
            raise APIError("rail_contract")
        terms = [x.casefold() for x in self.config.get("opportunity_terms", [])]
        candidates = []
        for row in rail["listings"]:
            if not row.get("open") or row.get("expiry", 0) <= self.now:
                continue
            capacity = row["economics"].get("available_award_capacity")
            if capacity is not None and capacity <= 0:
                continue
            if terms and not any(term in row["title"].casefold() for term in terms):
                continue
            candidates.append(row)
        # Rotate bounded detail reads rather than starving later listings.
        start = self.store.get("opportunities:offset", 0) % max(1, len(candidates))
        chosen = (candidates[start:] + candidates[:start])[:4]
        for row in chosen:
            detail = self.square.get("/api/listings/" + str(row["listing_id"]))
            opportunity = classify_opportunity(detail, self.now)
            if opportunity is None:
                continue
            key = "opportunity:" + str(row["listing_id"])
            fingerprint = digest(opportunity)
            if self.store.get(key) != fingerprint:
                if not square_policy.select_discovery(self.store, key, self.now):
                    self.store.disposition(key + ':' + fingerprint, 'attention_skipped', {'at': self.now, 'reason': 'square satiation'})
                    self.store.put(key, fingerprint)
                    continue
                if not self.emit(key + ":" + fingerprint, "Paid-work lead; not income or permission to commit: " + canonical(opportunity), ORIGIN + "/api/listings/" + str(row["listing_id"])):
                    return
                square_policy.record_attention(self.store, 'signals', self.now, key)
                self.store.put(key, fingerprint)
        self.store.put("opportunities:offset", start + len(chosen))

    def feed(self, feed):
        url = feed["url"]
        key = "feed:" + digest(url)
        cache = self.store.get(key, {})
        pending = self.store.get(key + ":pending")
        if pending is None:
            raw, etag, status = public_request(url, cache.get("etag"))
            if status == 304:
                return
            if b"<!DOCTYPE" in raw.upper() or b"<!ENTITY" in raw.upper():
                raise APIError("feed_entity_declarations_refused")
            try:
                root = ET.fromstring(raw)
            except ET.ParseError:
                # A transient truncated or malformed body from the upstream CDN
                # (observed on news.un.org): force one fresh full fetch rather
                # than failing the whole source and waking the mind.
                time.sleep(5)
                raw, etag, status = public_request(url, None)
                if status == 304:
                    raise
                if b"<!DOCTYPE" in raw.upper() or b"<!ENTITY" in raw.upper():
                    raise APIError("feed_entity_declarations_refused")
                root = ET.fromstring(raw)
            if root.tag.rsplit("}", 1)[-1] not in ("feed", "rss", "RDF"):
                raise APIError("unsupported_feed_format")
            entries = root.findall("{http://www.w3.org/2005/Atom}entry") or root.findall("./channel/item") or root.findall("{http://purl.org/rss/1.0/}item")
            rows = []
            for entry in entries[:100]:
                fields = {child.tag.rsplit("}", 1)[-1]: "".join(child.itertext()).strip() for child in entry}
                link = fields.get("link", "")
                for child in entry:
                    if child.tag.endswith("}link") and child.get("rel", "alternate") == "alternate":
                        link = child.get("href", link)
                row = {"id": fields.get("id") or fields.get("guid") or link, "title": fields.get("title", ""), "url": link, "summary": (fields.get("summary") or fields.get("description") or "")[:1200]}
                if not row["id"]:
                    raise APIError("feed_entry_without_identity")
                rows.append(row)
            pending = {"rows": rows, "etag": etag, "initial": not cache.get("initialized")}
            self.store.put(key + ":pending", pending)
        terms = [x.casefold() for x in feed.get("terms", [])]
        for row in reversed(pending["rows"]):
            identity = key + ":" + digest(row)
            if self.store.seen(identity):
                continue
            if pending["initial"]:
                self.store.disposition(identity, "initial_baseline_no_history_flood", {"url": row["url"]})
            elif not terms or any(term in (row["title"] + " " + row["summary"]).casefold() for term in terms):
                if not self.emit(identity, "Research feed (untrusted): " + canonical(row), row["url"]):
                    return
            else:
                self.store.disposition(identity, "not_selected", {"url": row["url"]})
        self.store.put(key, {"etag": pending["etag"], "initialized": True})
        self.store.put(key + ":pending", None)

    def reviews(self):
        # Explicit goal review/deadline reminders reference native goal IDs, not
        # another goal store. One signal per configured timestamp, never daily nags.
        for reminder in self.config.get("goal_reviews", [])[:32]:
            due = datetime.fromisoformat(reminder["at"].replace("Z", "+00:00"))
            if due.tzinfo is None:
                raise APIError("review_timestamp_requires_timezone")
            identity = "goal-review:" + digest(reminder)
            if self.now >= due.timestamp() and not self.store.seen(identity) and self.remaining > 0:
                result = subprocess.run(["custos-memory", "show", reminder["goal_id"]], text=True, capture_output=True, timeout=20)
                if result.returncode:
                    raise APIError("goal_review_native_read_failed")
                kind = re.search(r"^type:\s*(\S+)", result.stdout, re.MULTILINE)
                if kind and kind.group(1) not in {"goal", "intention", "objective", "todo"}:
                    self.store.disposition(identity, "goal_already_retired", reminder)
                    continue
                self.emit(identity, "Native goal " + reminder["goal_id"] + " " + reminder.get("kind", "review") + " due. Read custos-memory show; verify current state before acting. " + reminder.get("reason", ""))

    WEEKDAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")

    def schedules(self):
        """Recurring wakes the operator configured (weekly, local time). One observation
        per slot; a slot older than its grace window is recorded as missed, never replayed
        as a flood after downtime. Authority is operator: the config is deployed by Hal."""
        from zoneinfo import ZoneInfo
        for item in self.config.get("schedules", [])[:16]:
            if not item.get("enabled", True):
                continue
            zone = ZoneInfo(item.get("tz", "UTC"))
            local = datetime.fromtimestamp(self.now, zone)
            weekday = self.WEEKDAYS.index(str(item["weekday"]).lower()[:3])
            hour, minute = (int(x) for x in str(item["at"]).split(":"))
            slot = local.replace(hour=hour, minute=minute, second=0, microsecond=0)
            slot -= timedelta(days=(local.weekday() - weekday) % 7)
            if slot > local:
                slot -= timedelta(days=7)
            identity = "schedule:" + item["name"] + ":" + slot.strftime("%Y-%m-%dT%H:%M")
            if self.store.seen(identity):
                continue
            age = (local - slot).total_seconds()
            if age > int(item.get("grace_seconds", 6 * 3600)):
                self.store.disposition(identity, "schedule_missed", {"name": item["name"], "slot": slot.isoformat(), "late_seconds": int(age)})
                continue
            content = "Scheduled wake \"" + item["name"] + "\" (" + slot.strftime("%A %Y-%m-%d %H:%M %Z") + "): " + item["content"]
            if item.get('native_task'):
                self.native.capture({'request_id':identity,'sender':'operator:kitchen-schedule','authority':'operator',
                    'source_url':identity, 'content':content, 'next_action':content,
                    'completion':'Requested check-in has a verified submission receipt, or the household cancelled/skipped it; no purchase asserted.'}, deferred=True)
            if not self.emit(identity, content, authority="operator", schedule=item["name"]):
                return

    def daily_metrics(self):
        """Once a day: Custos's own numbers for the last 24 h as an observation,
        with the previous day's beside them for the trend (custos-observe metrics)."""
        metrics = self_metrics(self.native.path, self.now)
        day = time.strftime("%Y-%m-%d", time.gmtime(self.now))
        previous = self.store.get("metrics:latest")
        self.store.put("metrics:" + day, metrics)
        self.store.put("metrics:latest", metrics)
        self.native.append("metrics:" + day, {"type": "observation", "source": "metrics", "content": metrics_text(metrics, previous)})

    def housekeeping(self):
        """Every six hours, the bounded scratch cleanup above; the report is a state key
        (housekeeping:latest), never an observation, so it can never wake the mind."""
        logs = Path(self.native.path).resolve().parents[2] / "run/logs" if getattr(self.native, "path", None) else None
        report = housekeep(self.now, logs=logs)
        if os.environ.get('IDENTITY_DIR'):
            from custos_review_scratch import Registry
            report['review_scratch'] = Registry().clean()
        self.store.put("housekeeping:latest", report)

    def settled_prs(self):
        """PR numbers whose last github-prs snapshot is closed or merged, so their
        checkouts under /tmp can go as soon as the review goal closes."""
        numbers = set()
        for key, row in (self.store.get("github-prs:inventory", {}) or {}).items():
            state = self.store.get("github-prs:pr:" + key, {}) or {}
            pr = (state.get("snapshot") or {}).get("pr") or {}
            if pr.get("state") and pr["state"] != "open":
                numbers.add(str((row or {}).get("number") or key.rsplit("#", 1)[-1]))
        return numbers

    def expire_asks(self):
        """Deferred asks from other agents that nobody touched for a day are
        declined with evidence and announced to the mind (custos-memory expire-asks)."""
        hours = str(int(self.config.get("agent_ask_expiry_hours", 24)))
        result = subprocess.run(["custos-memory", "expire-asks", "--older-than", hours], capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise APIError("ask_expiry_failed")

    def outbox(self):
        path = self.native.path
        cursor = self.store.get("outbox:cursor", {"path": str(path), "offset": 0})
        if cursor["path"] != str(path) or cursor["offset"] > path.stat().st_size:
            raise APIError("outbox_trajectory_replaced_requires_explicit_migration")
        # The optional shortlist cannot turn into tomorrow's posting obligation.
        self.store.put('outbox:cursor', cursor)
        eligible = []
        for candidate in square_queue(self.store, path):
            try:
                composed = datetime.fromisoformat(candidate['ts'].replace('Z', '+00:00')).timestamp()
            except (ValueError, KeyError, AttributeError):
                composed = self.now
            if MAX_AGE_HOURS <= 0 or self.now - composed <= MAX_AGE_HOURS * 3600:
                eligible.append(candidate)
        for extra in eligible[square_policy.SHORTLIST:]:
            self.store.put('outbox:skip:' + extra['full_step_id'],
                           {'reason': 'square_shortlist_full', 'at': self.now})
        if self.store.get("outbox:cursor") is None:
            self.store.put("outbox:cursor", cursor)
        try:
            self._drain_outbox(path, cursor)
        finally:
            # Queue depth after this pass: square replies past the cursor that have
            # not gone out, so the mind can see how many wait behind the allowance.
            pending = square_queue(self.store, path)
            self.store.put("outbox:square_pending", {"count": len(pending), "oldest": pending[0]["ts"] if pending else None,
                                                      "items": pending[:200], "at": self.now})

    def _drain_outbox(self, path, cursor):
        # One pass reads from the cursor to the end of the log, bounded by time and
        # bytes rather than by a line count. The old 300-line cap meant a reset
        # drain advanced a few replies per tick: on 2026-09-11 clearing 53 stale and
        # withdrawn rows took from 00:00 to 02:18Z and two fresh replies aged past
        # the freshness cap while they waited their turn.
        deadline = time.monotonic() + DRAIN_SECONDS
        scanned = 0
        with path.open("rb") as source:
            source.seek(cursor["offset"])
            while scanned < DRAIN_MAX_BYTES and time.monotonic() < deadline:
                start = source.tell()
                line, status = read_native_line(source)
                if status in ("eof", "partial"):
                    break
                scanned += source.tell() - start
                if status == "oversized":
                    # A line longer than any square message (a reasoning or output
                    # step) is stepped over, once, out loud; it used to stop the
                    # source with outbox_native_line_too_large and freeze every reply
                    # behind it (2026-09-12: 19 replies, eleven hours, counter at 0).
                    self.native.append("oversized:%d" % start, {"type": "observation", "source": "square-outbox",
                                       "content": "Square outbox stepped over a %d-byte trajectory line at offset %d (longer than any square message; a reasoning or output step). Delivery continues past it." % (source.tell() - start, start)})
                    cursor["offset"] = source.tell()
                    self.store.put("outbox:cursor", cursor)
                    continue
                row = json.loads(line)
                if row.get("type") == "message" and row.get("from") == "custos" and str(row.get("to", "")).startswith("square:"):
                    match = re.fullmatch(r"square:([A-Za-z0-9_-]{2,32}):([1-9][0-9]*):(0|[1-9][0-9]*)", row["to"])
                    if not match or not row.get("step_id"):
                        raise APIError("invalid_square_outbox_target")
                    try:
                        composed = datetime.fromisoformat(row['ts'].replace('Z', '+00:00')).timestamp()
                    except (ValueError, KeyError, AttributeError):
                        composed = None
                    # Remember provenance even for withdrawn/expired native messages.
                    first_seen = square_policy.remember_candidate(self.store, row['content'], composed)
                    if self.store.get("outbox:skip:" + row["step_id"], None):
                        # Withdrawn by the mind (custos-observe withdraw STEP_ID): skip, never deliver.
                        self.native.append("withdrawn:" + row["step_id"], {"type": "observation", "source": "square-outbox",
                                           "content": "Square reply withdrawn before delivery (" + row["to"] + ").", "reply_to": row["step_id"]})
                        cursor["offset"] = source.tell()
                        self.store.put("outbox:cursor", cursor)
                        continue
                    if MAX_AGE_HOURS > 0 and row.get("ts"):
                        # Freshness cap: a reply composed more than MAX_AGE_HOURS ago is
                        # dropped undelivered rather than posted stale. The queue drains at
                        # only the daily allowance, so a backlog otherwise posts day-old
                        # takes onto threads that have moved on. Placed before the delivery
                        # attempt so stale replies clear even while the allowance is exhausted
                        # (they sit oldest-first at the head of the queue).
                        try:
                            composed = datetime.fromisoformat(row["ts"].replace("Z", "+00:00")).timestamp()
                        except (ValueError, KeyError, AttributeError):
                            composed = None
                        if composed is not None and (self.now - composed) > MAX_AGE_HOURS * 3600:
                            age_h = (self.now - composed) / 3600.0
                            note = ("Square reply to " + row["to"]
                                    + " dropped undelivered: composed %.1f h ago, past the %g h freshness cap. " % (age_h, MAX_AGE_HOURS)
                                    + "A day-old take is staler than no reply and the thread has moved on; "
                                    + "reply sooner or let it go. A queued reply is not a delivered one.")
                            self.native.append("stale:" + row["step_id"], {"type": "observation", "source": "square-outbox",
                                               "content": note, "reply_to": row["step_id"]})
                            cursor["offset"] = source.tell()
                            self.store.put("outbox:cursor", cursor)
                            continue
                    handle, post, parent = match.groups()
                    # Routing identity must still name the actual public addressee.
                    kind, target_id = ("comment", parent) if parent != "0" else ("post", post)
                    target = self.square.get("/api/" + kind + "/" + target_id)[kind]
                    if target.get("author") != handle:
                        raise APIError("outbox_recipient_mismatch")
                    payload = {"post_id": int(post), "body": row["content"]}
                    if parent != "0":
                        payload["parent_id"] = int(parent)
                    try:
                        # Original age is already registered above, including withdrawals.
                        receipt = self.square.write("traj:" + row["step_id"], "comment", payload)
                    except APIError as exc:
                        if exc.code == 'square_candidate_expired':
                            self.native.append('stale:' + row['step_id'], {'type': 'observation', 'source': 'square-outbox',
                                'content': 'Square candidate expired by its original composition time. It was not delivered; let it go, without restaging for reset.',
                                'reply_to': row['step_id']})
                            cursor['offset'] = source.tell()
                            self.store.put('outbox:cursor', cursor)
                            continue
                        if exc.code == "platform_allowance_exhausted":
                            # Tell the mind, once per reply, that this one is waiting. The
                            # cursor stays here so order is kept; the source retries at reset.
                            when = time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime(self.now + getattr(exc, "retry_after", 3600)))
                            queued = len(square_queue(self.store, path))
                            self.native.append("allowance-wait:" + row["step_id"], {"type": "observation", "source": "square-outbox",
                                               "content": "Square reply to @" + handle + " (thread " + post + ") is waiting for the daily comment allowance; "
                                                          + str(queued) + (" reply" if queued == 1 else " replies") + " queued; earliest allowance reconsideration about " + when
                                                          + ". This may expire before admission and creates no reset obligation. Withdraw with: custos-observe withdraw " + row["step_id"], "reply_to": row["step_id"]})
                        raise
                    self.native.append("delivery:" + row["step_id"], {"type": "observation", "source": "square-outbox", "content": "Public square reply delivered: " + canonical(receipt), "reply_to": row["step_id"]})
                if row.get("type") == "message" and row.get("from") == "custos" and str(row.get("to", "")).startswith("forum:"):
                    from custos_forum import Forum
                    match = re.fullmatch(r"forum:([A-Za-z0-9_-]{1,100}):([A-Za-z0-9_-]{1,100}):([A-Za-z0-9_-]{1,100})", row["to"])
                    if not match or not row.get("step_id"):
                        raise APIError("invalid_forum_outbox_target")
                    author, thread, parent = match.groups()
                    forum = Forum(config=self.config.get("forum", {}))
                    forum.identity()
                    target = forum.request("/api/messages/" + parent)["message"]
                    if target.get("authorName") != author or target.get("threadId") != thread:
                        raise APIError("forum_outbox_recipient_mismatch")
                    receipt = forum.write("traj:" + row["step_id"], "reply", {"threadId":thread, "parentId":parent, "body":row["content"]})
                    self.native.append("delivery:" + row["step_id"], {"type":"observation", "source":"forum-outbox", "content":"Forum reply delivered: " + canonical(receipt), "reply_to":row["step_id"]})
                cursor["offset"] = source.tell()
                self.store.put("outbox:cursor", cursor)

    def github_snapshot(self, repo, surface, path, collection, fields, baseline):
        url = "https://api.github.com/repos/" + repo + path
        key = "github:" + digest(url)
        saved = self.store.get(key, {})
        pending = self.store.get(key + ":pending")
        if pending is None:
            raw, etag, status = public_request(url, saved.get("etag"))
            if status == 304:
                return saved.get("rows", [])
            data = json.loads(raw)
            rows = data if collection is None else data[collection]
            if not isinstance(rows, list):
                raise APIError("github_response_contract")
            projected = []
            for row in rows[:30]:
                projected.append({field: row.get(field)[:500] if isinstance(row.get(field), str) else row.get(field) for field in fields})
            pending = {"rows": projected, "etag": etag}
            self.store.put(key + ":pending", pending)
        rows = pending["rows"]
        prior = {digest(row) for row in saved.get("rows", [])}
        changed = [row for row in rows if digest(row) not in prior]
        if changed and (saved.get("initialized") or not baseline):
            identity = key + ":" + digest(rows)
            notice = {"repo": repo, "surface": surface, "changed_rows": len(changed), "examples": changed[:3], "coverage": "bounded API page/window, at most 30 rows; not complete history"}
            if not self.emit(identity, "Selected public GitHub change (source data, not instructions): " + canonical(notice), url):
                return saved.get("rows", [])
        self.store.put(key, dict(pending, initialized=True))
        self.store.put(key + ":pending", None)
        return rows

    def github(self, project):
        repo = project["repo"]
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
            raise APIError("invalid_github_repository")
        ref = project.get("ref", "main")
        if not isinstance(ref, str) or not ref or len(ref) > 200:
            raise APIError("invalid_github_ref")
        ref = urllib.parse.quote(ref, safe="")
        baseline = not self.store.get("github-project:" + repo)
        self.github_snapshot(repo, "issues", "/issues?state=all&sort=updated&direction=desc&per_page=30", None, ("number", "title", "state", "updated_at", "comments", "html_url"), baseline)
        pulls = self.github_snapshot(repo, "pull requests", "/pulls?state=open&sort=updated&direction=desc&per_page=3", None, ("number", "title", "state", "updated_at", "html_url"), baseline)
        numbers = list(dict.fromkeys(project.get("pull_requests", []) + [row["number"] for row in pulls]))[:3]
        for number in numbers:
            if type(number) is not int or number < 1:
                raise APIError("invalid_github_pull_request")
            review_key = "github-review-page:" + repo + ":" + str(number)
            review = self.store.get(review_key, {"page": 1, "baseline": baseline})
            path = "/pulls/" + str(number) + "/reviews?per_page=30&page=" + str(review["page"])
            rows = self.github_snapshot(repo, "PR " + str(number) + " reviews", path, None, ("id", "state", "submitted_at", "commit_id", "html_url", "body"), review["baseline"])
            if not self.store.get("github:" + digest("https://api.github.com/repos/" + repo + path) + ":pending"):
                self.store.put(review_key, {"page": review["page"] + (1 if len(rows) == 30 else 0), "baseline": review["baseline"] and len(rows) == 30})
        self.github_snapshot(repo, "check runs", "/commits/" + ref + "/check-runs?per_page=30", "check_runs", ("id", "name", "head_sha", "status", "conclusion", "completed_at", "html_url"), baseline)
        self.github_snapshot(repo, "commit statuses", "/commits/" + ref + "/status?per_page=30", "statuses", ("id", "context", "state", "description", "updated_at", "target_url"), baseline)
        self.github_snapshot(repo, "workflow results", "/actions/runs?per_page=20", "workflow_runs", ("id", "name", "head_sha", "status", "conclusion", "updated_at", "html_url"), baseline)
        self.store.put("github-project:" + repo, True)

    def local_results(self):
        pending = self.store.db.execute("SELECT s.key,s.value FROM state s LEFT JOIN seen d ON d.id=s.key WHERE s.key LIKE 'work-result:%' AND d.id IS NULL ORDER BY s.key LIMIT 12").fetchall()
        for row in pending:
            result = json.loads(row["value"])
            identity = "work-result:" + result["request_id"]
            if self.store.seen(identity):
                continue
            notice = {"project": result["project"], "kind": result["kind"], "status": result["status"], "summary": result["summary"], "evidence": result["evidence"], "goal_id": result.get("goal_id"), "basis": "local worker-reported outcome with retained file digests; not independent verification or a financial receipt"}
            if not self.emit(identity, "Owned-work outcome: " + canonical(notice), result.get("source_url", ""), authority="agent"):
                return

    def local_git(self, project):
        path = Path(project["path"])
        if not path.is_absolute():
            raise APIError("local_project_requires_absolute_path")
        def git(*args):
            result = subprocess.run(["git", "--no-pager", "-C", str(path), *args], capture_output=True, text=True, timeout=20, env=dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0"))
            if result.returncode:
                raise APIError("local_git_read_failed")
            return result.stdout.strip()
        head = git("rev-parse", "--verify", "HEAD")
        commits = git("log", "--max-count=5", "--format=%h %s").splitlines()
        # Stats only: do not pass private file contents or remote credentials into
        # observation context. Untracked files are not represented as deliveries.
        diff = git("diff", "--no-ext-diff", "--stat", "--stat-count=10", "HEAD", "--")
        snapshot = {"project": project["name"], "path": str(path), "head": head, "commits": [line[:300] for line in commits], "tracked_worktree_stat": diff[:2000], "scope": "local committed HEAD and tracked working-tree diff only; no claim of test, delivery, review or CI success"}
        key = "local-git:" + digest(str(path))
        old = self.store.get(key)
        if old is not None and old != snapshot:
            if not self.emit(key + ":" + digest(snapshot), "Owned local project changed: " + canonical(snapshot), path.as_uri(), authority="agent"):
                return
        self.store.put(key, snapshot)

    def admission(self):
        from custos_admission import check
        identity = os.environ.get("IDENTITY_DIR", "/var/lib/custos-harness/identities/custos")
        result = check(identity)
        url = result["url"] + "/health"
        state = result["state"]
        if state in {"custos_request_in_flight", "backend_busy_or_unavailable"}:
            return  # shared short retry, not a lasting incident
        message = ("Inference admitted again by gateway health; normal work may resume."
                   if state == "admitted" else
                   "Inference deferred by gateway health: " + state +
                   ". Known denial is shared across wakes; no model calls until the next health probe. "
                   "This is an observed gateway result, not evidence of an operator pause unless the code explicitly says so. "
                   "Preserve goals and respect the boundary.")
        previous = self.store.get("admission:status", {"state": None, "sequence": 0})
        if previous["state"] != state:
            sequence = previous["sequence"] + 1
            if self.emit("admission:" + str(sequence), message, url):
                self.store.put("admission:status", {"state": state, "sequence": sequence})

    def forum_poll(self, kind):
        from custos_forum import Forum, poll
        poll(self, Forum(config=self.config["forum"]), kind)

    def run(self):
        # Local storage gets the first observation slot, before network sources.
        from custos_disk_space import observe as disk_space
        self.source("disk-space", 300, lambda: disk_space(self))
        self.source("square-outbox", 60, self.outbox)
        from custos_news import drain as drain_news
        self.source("ai-news-review", 60, lambda: drain_news(self))
        if self.config.get("github_prs", {}).get("enabled"):
            from custos_github_prs import poll as poll_prs
            self.source("github-prs", 300, lambda: poll_prs(self))
        self.source("ask-expiry", 3600, self.expire_asks)
        self.source("self-metrics", 86400, self.daily_metrics)
        self.source("housekeeping", 21600, self.housekeeping)
        self.source("square-inbox", 300, self.inbox)
        if self.config.get("forum", {}).get("enabled"):
            self.source("forum-inbox", 300, lambda: self.forum_poll("inbox"))
            self.source("forum-feed", 1800, lambda: self.forum_poll("feed"))
        self.source("owned-work-results", 300, self.local_results)
        self.source("inference-admission", 300, self.admission)
        for project in self.config.get("local_projects", [])[:4]:
            if project.get("enabled", True):
                self.source("local-git:" + project["name"], max(1800, int(project.get("interval_seconds", 1800))), lambda project=project: self.local_git(project))
        for project in self.config.get("github_projects", [])[:2]:
            if project.get("enabled", True):
                self.source("github:" + project["repo"], max(7200, int(project.get("interval_seconds", 7200))), lambda project=project: self.github(project))
        self.source("square-changes", 1800, self.changes)
        self.source("paid-opportunities", 21600, self.opportunities)
        for feed in self.config.get("research_feeds", [])[:8]:
            if feed.get("enabled", True):
                self.source("research:" + feed["name"], max(3600, int(feed.get("interval_seconds", 21600))), lambda feed=feed: self.feed(feed))
        self.source("reviews", 3600, self.reviews)
        self.source("schedules", 60, self.schedules)


def classify_opportunity(detail, now):
    if detail.get("expired") or detail.get("withdrawn_at") or detail.get("mod_state") or detail.get("expiry", 0) <= now:
        return None
    if detail.get("submission_deadline") and detail["submission_deadline"] <= now:
        return None
    economics = detail["economics"]
    capacity = economics.get("available_award_capacity")
    if capacity is not None and capacity <= 0:
        return None
    funding = detail.get("funding_status") or {}
    mode = detail.get("funding_mode")
    if mode == "funded":
        if funding.get("funded") is not True:
            return None
        remaining = int((funding.get("onchain") or {}).get("remaining_atomic", "0"))
        if remaining < int(economics.get("maximum_remaining_liability_atomic") or detail["amount_atomic"]):
            return None
        label = "chain-read committed funding; acceptance/claim conditions still apply"
    elif detail.get("funder_address") and int(detail.get("funds_seen_atomic") or 0) >= int(detail["amount_atomic"]):
        label = "historical wallet snapshot only; NOT locked, reserved or guaranteed"
    else:
        return None
    return {"listing_id": detail["listing_id"], "title": detail["title"], "amount_atomic": detail["amount_atomic"], "asset": {"chain_id": detail["chain_id"], "token": detail["token"]}, "available_award_capacity": capacity, "capacity_note": "unknown legacy award capacity" if capacity is None else "declared remaining slots", "funding": label, "funds_checked_at": detail.get("funds_checked_at"), "expiry": detail["expiry"], "condition": detail["condition"][:1600], "submissions": detail.get("submissions_total"), "autonomous_spend": 0}


def import_continuity(store, snapshot):
    items = snapshot.get("items")
    if not isinstance(items, list) or len(items) > 1000:
        raise APIError("invalid_continuity_items")
    items = [dict(item) for item in items]
    for item in items:
        if not re.fullmatch(r"square:(comment|post):[1-9][0-9]*", item["request_id"]):
            raise APIError("invalid_continuity_request")
        kind, source_id = item["request_id"].split(":")[1:]
        if not str(item.get("sender", "")).startswith("square:"):
            item["sender"] = square_sender(item["sender"], item.get("post_id"),
                                           int(source_id) if kind == "comment" else 0)
        if not re.fullmatch(r"square:[A-Za-z0-9_-]{2,32}:[1-9][0-9]*:(0|[1-9][0-9]*)", item["sender"]):
            raise APIError("invalid_continuity_sender")
        if not isinstance(item["content"], str) or not item["source_url"].startswith(ORIGIN + "/api/"):
            raise APIError("invalid_continuity_source")
        if any(type(reply) is not int or reply < 1 for reply in item.get("previous_replies", [])):
            raise APIError("invalid_continuity_reply")
    # Entire import is atomic and replayable; importing never ACKs the snapshot.
    with store.db:
        for item in items:
            if item.get("previous_replies"):
                proof = {"source_url": item["source_url"], "previous_replies": [ORIGIN + "/api/comment/" + str(reply) for reply in item["previous_replies"]], "basis": "operator-qualified pre-reset continuity; do not renew fulfilled asks"}
                store.db.execute("INSERT OR IGNORE INTO seen VALUES (?,?,?)", (item["request_id"], "fulfilled_before_reset", canonical(proof)))
        store.db.execute("INSERT OR REPLACE INTO state VALUES (?,?)", ("continuity:items", canonical(items)))
        store.db.execute("INSERT OR REPLACE INTO state VALUES (?,?)", ("continuity:original_ack_cursor", canonical(snapshot.get("ack_cursor"))))
    return {"imported": len(items), "already_fulfilled": sum(bool(i.get("previous_replies")) for i in items), "acknowledged": False}

def record_result(store, result):
    required = {"request_id", "project", "kind", "status", "summary", "evidence"}
    if not isinstance(result, dict) or not required.issubset(result) or set(result) - required - {"goal_id", "source_url"}:
        raise APIError("invalid_work_result_fields")
    if not isinstance(result["request_id"], str) or not re.fullmatch(r"[A-Za-z0-9:_-]{1,200}", result["request_id"]):
        raise APIError("invalid_work_result_id")
    if result["kind"] not in {"experiment", "test", "delivery", "review"} or result["status"] not in {"succeeded", "failed", "blocked", "feedback"}:
        raise APIError("invalid_work_result_state")
    if any(not isinstance(result[key], str) or not 1 <= len(result[key]) <= limit for key, limit in (("project", 200), ("summary", 2000))):
        raise APIError("invalid_work_result_text")
    for key, limit in (("goal_id", 100), ("source_url", 2048)):
        if key in result and (not isinstance(result[key], str) or len(result[key]) > limit):
            raise APIError("invalid_work_result_reference")
    if not isinstance(result["evidence"], list) or not 1 <= len(result["evidence"]) <= 8:
        raise APIError("work_result_requires_retained_evidence")
    for evidence in result["evidence"]:
        if not isinstance(evidence, dict) or set(evidence) != {"path", "sha256"} or not re.fullmatch(r"[0-9a-f]{64}", evidence["sha256"]):
            raise APIError("invalid_work_result_evidence")
        path = Path(evidence["path"])
        if not path.is_absolute():
            raise APIError("work_result_evidence_requires_absolute_path")
        with path.open("rb") as source:
            raw = source.read(8 * 1024 * 1024 + 1)
        if len(raw) > 8 * 1024 * 1024 or hashlib.sha256(raw).hexdigest() != evidence["sha256"]:
            raise APIError("work_result_evidence_digest_mismatch")
    key = "work-result:" + result["request_id"]
    with store.db:
        store.db.execute("BEGIN IMMEDIATE")
        prior = store.db.execute("SELECT value FROM state WHERE key=?", (key,)).fetchone()
        if prior and json.loads(prior["value"]) != result:
            raise APIError("work_result_id_conflict")
        store.db.execute("INSERT OR IGNORE INTO state VALUES (?,?)", (key, canonical(result)))
    # The next observation run emits this durable callback, with no model call here.
    return {"request_id": result["request_id"], "queued": True, "created": prior is None}

def resolve_outbox_step_ids(store, prefix):
    """Full step_ids of outgoing square rows past the outbox cursor whose
    id starts with prefix. The delivery filter matches the full row id, so
    a withdrawal stored under a shorter key silently no-ops (2026-09-10:
    eight withdrawals bound to 8-char prefixes were never applied)."""
    cursor = store.get("outbox:cursor")
    if not isinstance(cursor, dict) or not cursor.get("path"):
        return []
    path = Path(cursor["path"])
    if not path.is_file():
        return []
    matches = []
    try:
        with path.open("rb") as probe:
            probe.seek(int(cursor.get("offset", 0)))
            while True:
                line, status = read_native_line(probe)
                if status in ("eof", "partial"):
                    break
                if status == "oversized":
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if (row.get("type") == "message" and row.get("from") == "custos"
                        and str(row.get("to", "")).startswith("square:")):
                    sid = str(row.get("step_id", ""))
                    if sid.startswith(prefix):
                        matches.append(sid)
    except OSError:
        return []
    return matches
def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("once", "status", "import-continuity", "record-result", "withdraw", "metrics"))
    parser.add_argument("step_id", nargs="?", help="withdraw: the outgoing square message step id to skip")
    parser.add_argument("--config", type=Path, default=CONFIG)
    parser.add_argument("--file", type=Path)
    args = parser.parse_args(argv)
    store = Store()
    if args.command == "status":
        print(canonical({"sources": {row["key"]: json.loads(row["value"]) for row in store.db.execute("SELECT * FROM state WHERE key LIKE 'source:%'")},
                         "outbox": [dict(row) for row in store.db.execute("SELECT id,status,receipt FROM outbound ORDER BY started DESC LIMIT 30")],
                         "square_pending": (lambda q: {"count": len(q), "items": q[:200], "note": "every queued reply, oldest first; items past 200 are omitted"})(square_queue(store)),
                         "square_allowance": allowance_summary(store),
                         "inbox_page_pending": store.get("inbox:page") is not None}))
        return 0
    if args.command == "metrics":
        root = os.environ.get("ROOT_TRAJ_ID") or os.environ.get("TRAJ_ID")
        traj_path = subprocess.run(["traj", "path", root], check=True, capture_output=True, text=True, timeout=20).stdout.strip()
        metrics = self_metrics(Path(traj_path), time.time())
        print(canonical(metrics) if args.file else metrics_text(metrics, store.get("metrics:latest")))
        return 0
    if args.command == "withdraw":
        if not args.step_id or not re.fullmatch(r"[0-9a-f-]{8,64}", args.step_id):
            print("custos-observe withdraw STEP_ID (the full step id of your outgoing square message)", file=sys.stderr)
            return 2
        matches = resolve_outbox_step_ids(store, args.step_id)
        if len(matches) > 1:
            print("custos-observe withdraw: %s matches %d outgoing square rows; pass a unique full step id: %s" % (args.step_id, len(matches), ", ".join(m[:8] for m in matches[:4])), file=sys.stderr)
            return 2
        target = matches[0] if matches else args.step_id
        store.put("outbox:skip:" + target, {"at": time.time(), "requested": args.step_id})
        note = "skipped at the next outbox pass; already-delivered replies cannot be withdrawn"
        if not matches:
            note += "; no outgoing square row past the cursor matched this id - verify the row is undelivered"
        print(canonical({"withdrawn": target, "matched_row": bool(matches), "note": note}))
        return 0
    try:
        with (STATE / "run.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                if args.command != "once":
                    raise APIError("observer_busy_callback_not_queued_retry")
                return 0
            if args.command == "record-result":
                if args.file is None:
                    raise APIError("work_result_file_required")
                print(canonical(record_result(store, json.loads(args.file.read_text()))))
                return 0
            if args.command == "import-continuity":
                if args.file is None:
                    raise APIError("continuity_file_required")
                print(canonical(import_continuity(store, json.loads(args.file.read_text()))))
                return 0
            config = json.loads(args.config.read_text())
            Observer(config, store, Square(store), Native(store)).run()
        return 0
    except (APIError, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as exc:
        print(canonical({"error": exc.code if isinstance(exc, APIError) else type(exc).__name__}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
