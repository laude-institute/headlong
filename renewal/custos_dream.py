"""Scheduled memory review inside the existing mind. No inference or network here."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from zoneinfo import ZoneInfo

import custos_memory as cm

UTC = dt.timezone.utc
DEFAULTS = {"enabled": True, "timezone": "America/Denver", "start": "03:30", "end": "05:00",
            "minutes": 20, "batch_size": 40, "max_edits": 20}

def sha(raw):
    return hashlib.sha256(raw).hexdigest()

def atomic(path, raw):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix=".dream-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(raw); f.flush(); os.fsync(f.fileno())
        os.replace(name, path)
        fd = os.open(path.parent, os.O_RDONLY)
        try: os.fsync(fd)
        finally: os.close(fd)
    finally:
        if os.path.exists(name): os.unlink(name)

def write_json(path, value):
    atomic(path, (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode())

def read_json(path, default=None):
    return json.loads(path.read_text()) if path.exists() else default

def unscoped_contact_rule(summary, body):
    claim = summary + '\n' + body
    return bool(re.search(r'Signal', claim, re.I) and re.search(r'guard|cooldown|double.text', claim, re.I)
                and re.search(r'\b\d+\s*(?:h|hours?)\b', summary, re.I)
                and not re.search(r'\b(?:social|mind|ordinary|bot)\b', summary, re.I))


class Dream:
    def __init__(self, store=None, root=None, config=None, clock=None):
        self.store = store or cm.Store()
        self.root = Path(root or self.store.directory.parent / "dream")
        self.config = dict(DEFAULTS, **(config if config is not None else read_json(Path("/var/lib/custos/config/dream.json") if Path("/var/lib/custos/config/dream.json").exists() else Path(__file__).with_name("dream.json"), {})))
        self.clock = clock or (lambda: dt.datetime.now(UTC))
        self.zone = ZoneInfo(self.config["timezone"])
        self.start = dt.time.fromisoformat(self.config["start"])
        self.end = dt.time.fromisoformat(self.config["end"])
        if self.start >= self.end or not 1 <= self.config["minutes"] <= 60 or not 1 <= self.config["batch_size"] <= 100 or not 1 <= self.config["max_edits"] <= 40:
            raise ValueError("invalid dream schedule or bounds")

    def stamp(self): return self.clock().astimezone(UTC).isoformat()
    def day(self): return self.clock().astimezone(self.zone).date().isoformat()
    def window(self):
        local = self.clock().astimezone(self.zone)
        return self.config["enabled"] and self.start <= local.time().replace(tzinfo=None) < self.end
    def session_path(self): return self.root / self.day() / "session.json"

    def inventory(self):
        reviewed = read_json(self.root / "reviewed.json", {})
        rows = []
        proposals = {read_json(p).get("person_key") for p in (self.root / "person-proposals").glob("*.json")}
        for path, header, body, fields, record in self.store.files():
            key = fields["id"]; digest = sha(path.read_bytes()); flags = []
            if not fields.get("summary") or fields.get("summary") == "---": flags.append("bad-summary")
            if body.startswith("---\n"): flags.append("nested-frontmatter")
            if record and record.get("status") == "active" and record["origin"].get("ambient") and not cm.is_task(record) and not record.get("response") and not record.get("responder_attempt"):
                flags.append("unsettled-ambient")
            if cm.PERSON_MARKER in body:
                note = body.split(cm.PERSON_MARKER)[0]
                try:
                    person = json.JSONDecoder().raw_decode(body.split(cm.PERSON_MARKER, 1)[1].lstrip())[0]
                    if person.get("person_key") in proposals: flags.append("person-candidate")
                except (ValueError, TypeError): flags.append("invalid-person-metadata")
                if len(note) > cm.PERSON_NOTE_MAX + 100: flags.append("long-person-note")
            if re.search(r'(?m)^(?:STAGED|Left:|Next:)', body) and re.search(r'(?m)^(?:DONE|DELIVERED)', body): flags.append("historical-instructions-first")
            if record and record.get("status") == "completed" and cm.is_task(record):
                evidence = record.get("resolution", {}).get("evidence", "").lower()
                if "queued" in evidence or "readback pending" in evidence: flags.append("verify-completion-receipt")
            # Selection hints, not factual verdicts. Reserve review space for
            # claims where a correction/counterexample could change behavior.
            if not record and re.search(r"\b(?:correction|counterevidence|contradict\w*|refuted|nonsignificant|not statistically significant|uncertain|causal|inference.layer|repeated failure)\b", body, re.I):
                flags.append("challenge-claim")
            if not record and unscoped_contact_rule(fields.get('summary', ''), body):
                flags.append('contact-rule-scope')
            prior = reviewed.get(key, {})
            rows.append({"id": key, "type": fields.get("type"), "sha256": digest, "bytes": path.stat().st_size,
                         "summary": fields.get("summary", "")[:160], "status": record.get("status") if record else None,
                         "conversation": bool(record and not cm.is_task(record)), "flags": flags,
                         "reviewed_at": prior.get("at", "") if prior.get("sha256") == digest else ""})
        return rows

    def journals(self, s):
        paths = sorted((self.root / s["day"] / "changes").glob("*.json"))
        for path in paths:
            entry = read_json(path)
            if entry["status"] == "prepared":
                target = Path(entry["target"])
                if target.exists() and sha(target.read_bytes()) == entry["after_sha256"] and (entry["operation"] != "archive" or not Path(entry["source"]).exists()):
                    entry["status"] = "applied"; write_json(path, entry)
        s["edits"] = [str(p) for p in paths]  # prepared writes also consume budget
        return s

    def due(self):
        with self.store.lock("dream-schedule"):
            for prior in sorted(self.root.glob("????-??-??/session.json")):
                old = read_json(prior)
                if old["status"] in {"pending", "running"} and (old["day"] < self.day() or
                    (old.get("deadline") and self.stamp() >= old["deadline"]) or
                    (old["day"] == self.day() and self.clock().astimezone(self.zone).time().replace(tzinfo=None) >= self.end)):
                    self._finish(old, "expired", "Window or review budget elapsed; unreviewed entries carry forward.")
            if not self.window(): return ""
            path = self.session_path(); session = read_json(path)
            if session and session["status"] in {"complete", "partial", "expired"}: return ""
            if not session:
                rows = self.inventory()
                # Conversations are primarily historical event receipts. Review their
                # lifecycle flags; rotate the substantive store fairly by last review.
                candidates = [r for r in rows if not r["conversation"] or r["flags"]]
                candidates.sort(key=lambda r: (r["reviewed_at"], not bool(r["flags"]), r["type"] == "memory", r["id"]))
                budget = self.config["batch_size"]
                # At most half the batch is reserved for risk; the rest follows
                # oldest-review rotation so flags cannot starve ordinary memory.
                critical = [r for r in candidates if r["flags"]][:max(1, budget // 2)]
                picked = {r["id"] for r in critical}
                selected = critical + [r for r in candidates if r["id"] not in picked][:budget - len(critical)]
                session = {"version": 1, "day": self.day(), "created": self.stamp(), "status": "pending",
                           "inventory_count": len(rows), "selected": selected, "reviews": {}, "edits": [],
                           "max_edits": self.config["max_edits"], "minutes": self.config["minutes"]}
                write_json(path.parent / "inventory.json", rows); write_json(path, session)
            if session.get("deadline") and self.stamp() >= session["deadline"]:
                self._finish(session, "expired", "Review time budget elapsed; unreviewed entries carry forward.")
                return ""
            if not session.get("announced"):
                if os.environ.get("TRAJ_ID"):
                    cm.append_step({"type": "observation", "source": "memory-dream",
                                    "content": "Scheduled memory review due for " + self.day() + "; load custos-dream. No edits have been implied by this schedule."})
                session["announced"] = True; write_json(path, session)
            return ("Hal's scheduled memory dream is due (" + self.day() + ", America/Denver). "
                    "Choose dream before discretionary explore/make; urgent directed work may take priority. "
                    "Run skills show custos-dream, then custos-dream begin. Review at most " + str(len(session["selected"])) +
                    " selected records, at most " + str(session["max_edits"]) + " edits, " + str(session["minutes"]) +
                    " minutes. Include a brief persona reflection; keeping it unchanged is valid. "
                    "Use existing serial inference. No messages, deployment, or new authority are part of this review.")

    def begin(self):
        if not self.window(): raise ValueError("outside early-morning dream window")
        self.due()
        with self.store.lock("dream-schedule"):
            s = read_json(self.session_path())
            if not s or s["status"] not in {"pending", "running"}: raise ValueError("dream already finished for this local day")
            if not s.get("deadline"):
                s["started"] = self.stamp()
                end = dt.datetime.combine(self.clock().astimezone(self.zone).date(), self.end, self.zone).astimezone(UTC)
                s["deadline"] = min(self.clock().astimezone(UTC) + dt.timedelta(minutes=s["minutes"]), end).isoformat()
                s["status"] = "running"; write_json(self.session_path(), s)
            result = dict(s)
            if (self.store.directory.parent / 'core_identity_prompt.md').exists():
                from custos_persona import Persona
                result['persona'] = Persona(self).show()
            return result

    def active(self):
        s = read_json(self.session_path())
        if not self.window() or not s or s["status"] != "running" or self.stamp() >= s["deadline"]:
            raise ValueError("no active dream budget; finish/report, do not continue editing")
        return self.journals(s)

    def revise(self, key, expected, body, evidence, archive=False, replacement=None, operator=False, memory_type=None):
        """CAS and preimage backups. Operator is for explicit one-time migrations,
        not a CLI switch available in the scheduled workflow."""
        if not evidence.strip(): raise ValueError("specific evidence is required")
        s = None if operator else self.active()
        if s and (key not in {r["id"] for r in s["selected"]} or len(s["edits"]) >= s["max_edits"]): raise ValueError("record or edit outside review budget")
        with self.store.lock():
            if s:
                s = self.active()
                if len(s["edits"]) >= s["max_edits"]: raise ValueError("edit budget exhausted")
            item = self.store.find(key); path, header, old, fields, record = item
            raw = path.read_bytes()
            if sha(raw) != expected: raise ValueError("memory changed since inspection; re-read before editing")
            if archive:
                if fields.get("type") in cm.GOAL_TYPES or fields.get("type") in {"value", "person"} or record:
                    raise ValueError("archive only ordinary superseded facts/notes/memories; preserve people, values, and request receipts")
                if not replacement or replacement == key: raise ValueError("canonical replacement ID required")
                self.store.find(replacement)
            else:
                if not body or len(body.encode()) > 131072: raise ValueError("invalid replacement body")
                if not operator:
                    if fields.get("type") == "value": raise ValueError("values need explicit operator-approved revision; record uncertainty")
                    if record:
                        if cm.MARKER not in body or cm.strict_json(body.split(cm.MARKER, 1)[1]) != record:
                            raise ValueError("preserve request origin, state, response, and evidence; annotate before its record")
                    elif cm.MARKER in body: raise ValueError("cannot manufacture request provenance")
                    if fields.get("type") == "person":
                        if cm.PERSON_MARKER not in body or cm.strict_json(body.rsplit(cm.PERSON_MARKER, 1)[1]) != cm.strict_json(old.rsplit(cm.PERSON_MARKER, 1)[1]):
                            raise ValueError("preserve trusted person identity and routes")
                        if body.startswith("---") or len(body.split(cm.PERSON_MARKER)[0]) > cm.PERSON_NOTE_MAX + 80:
                            raise ValueError("person body must be compact complete prose, not frontmatter")
                # Keep ID, created, type, expiry and custom fields. Summary is quoted
                # JSON (also valid YAML), so colons or '---' cannot corrupt headers.
                if memory_type:
                    if not operator: raise ValueError("category changes require explicit operator migration")
                    header = re.sub(r'(?m)^type:.*$', 'type: ' + memory_type, header)
                summary = json.dumps(body.splitlines()[0][:160], ensure_ascii=False)
                header = re.sub(r'(?m)^summary:.*$', lambda _: 'summary: ' + summary, header)
                candidate = ("---\n" + header + "\n---\n\n" + body.strip() + "\n").encode()
            journal_dir = self.root / ("operator-cleanup" if operator else self.day()) / "changes"
            journal_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
            change_id = key + "-" + expected[:16]
            before = journal_dir / (change_id + ".before.md")
            journal = journal_dir / (change_id + ".json")
            target = self.store.archive_dir() / path.name if archive else path
            after_hash = expected if archive else sha(candidate)
            entry = {"id": key, "at": self.stamp(), "evidence": evidence, "before_sha256": expected,
                     "after_sha256": after_hash, "source": str(path), "target": str(target),
                     "backup": str(before), "operation": "archive" if archive else "revise",
                     "replacement": replacement, "status": "prepared"}
            if before.exists(): raise ValueError("prepared change exists; inspect journal before retrying")
            atomic(before, raw); write_json(journal, entry)
            if archive:
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                if target.exists(): raise ValueError("archive collision")
                os.replace(path, target); self.store.sync(target)
                fd = os.open(target.parent, os.O_RDONLY)
                try: os.fsync(fd)
                finally: os.close(fd)
            else: atomic(path, candidate)
            if sha(target.read_bytes()) != after_hash: raise ValueError("memory readback failed; preserved preimage")
            entry["status"] = "applied"; write_json(journal, entry)
        if s:
            with self.store.lock("dream-schedule"):
                fresh = self.journals(read_json(self.session_path())); write_json(self.session_path(), fresh)
        return entry

    def review(self, key, expected, verdict, evidence):
        return self.review_batch([{"id": key, "expected": expected, "verdict": verdict, "evidence": evidence}])[key]

    def review_batch(self, decisions):
        """Validate the entire bounded batch before recording any decision."""
        if not isinstance(decisions, list) or not 1 <= len(decisions) <= self.config['batch_size']:
            raise ValueError("review batch must be a nonempty list within the selection budget")
        with self.store.lock("dream-schedule"), self.store.lock():
            s = self.active()
            entries = [read_json(Path(p)) for p in s["edits"]]
            updates = {}
            for decision in decisions:
                if not isinstance(decision, dict) or not {'id', 'expected', 'verdict', 'evidence'} <= set(decision) or set(decision) - {'id', 'expected', 'verdict', 'evidence', 'counterevidence'}:
                    raise ValueError("each review requires id, expected, verdict and evidence")
                key, expected, verdict, evidence = (decision[k] for k in ('id', 'expected', 'verdict', 'evidence'))
                if not isinstance(key, str) or key not in {r['id'] for r in s['selected']}:
                    raise ValueError("not selected for this dream")
                if key in updates: raise ValueError("duplicate review ID in batch")
                if not isinstance(expected, str) or not re.fullmatch(r'[0-9a-f]{64}', expected):
                    raise ValueError("current expected SHA-256 required for every review")
                if not isinstance(verdict, str) or verdict not in {'keep', 'uncertain', 'revised', 'archived'} or not isinstance(evidence, str) or not evidence.strip() or len(evidence) > 4096:
                    raise ValueError("verdict and bounded specific evidence required")
                matches = [e for e in entries if e['id'] == key and e['status'] == 'applied']
                if verdict == 'archived':
                    archives = [e for e in matches if e['operation'] == 'archive']
                    if not archives: raise ValueError("no verified archive receipt")
                    actual = sha(Path(archives[-1]['target']).read_bytes())
                else: actual = sha(self.store.find(key)[0].read_bytes())
                if actual != expected: raise ValueError("reviewed bytes changed: " + key)
                if verdict == 'revised' and not any(e['operation'] == 'revise' and e['after_sha256'] == actual for e in matches):
                    raise ValueError("no revision receipt for reviewed bytes")
                if verdict == 'keep':
                    item = self.store.find(key)
                    if unscoped_contact_rule(item[3].get('summary', ''), item[2]):
                        raise ValueError('contact rule summary lacks mode: check mind/social policy, revise or mark uncertain')
                contrary = decision.get('counterevidence', '')
                if not isinstance(contrary, str) or len(contrary) > 4096:
                    raise ValueError('bounded counterevidence text required')
                updates[key] = {'counterevidence': contrary, 'verdict': verdict, 'sha256': actual, 'evidence': evidence, 'at': self.stamp()}
            s['reviews'].update(updates)
            write_json(self.session_path(), s)
            # Session is authoritative. If interrupted before this index write,
            # replaying the batch repairs rotation without inventing decisions.
            seen = read_json(self.root / "reviewed.json", {})
            seen.update({key: {'sha256': r['sha256'], 'at': r['at']} for key, r in updates.items()})
            write_json(self.root / "reviewed.json", seen)
        return updates

    def finish_preview(self):
        with self.store.lock('dream-schedule'):
            s = read_json(self.session_path())
            if not s: raise ValueError('no dream scheduled today')
            missing = [r['id'] for r in s['selected'] if r['id'] not in s['reviews']]
            return {'day': s['day'], 'status': s['status'], 'selected': len(s['selected']),
                    'reviewed': len(s['reviews']), 'missing': missing,
                    'persona_reviewed': bool(s.get('persona_reflection')),
                    'can_continue': s['status'] == 'running' and self.window() and self.stamp() < s.get('deadline', ''),
                    'finish_status': 'partial' if missing else 'complete',
                    'warning': 'Finish closes today irreversibly; missing decisions carry forward. Reading is not a recorded review.'}

    # ---- the day's trajectory, audited (Hal, 2026-09-12: "the dream skill should not just go through
    # memories. It should go through the entire day's trajectory, audit problems, and set its own
    # deferred goals for fixing them or raising them to me or Kim in the Signal chat") ----
    def trajectory_path(self):
        root = os.environ.get("ROOT_TRAJ_ID")
        if not root: return None
        try:
            import subprocess
            return Path(subprocess.check_output(["traj", "path", root], stderr=subprocess.DEVNULL, timeout=20).decode().strip())
        except Exception: return None  # noqa: BLE001 - no trajectory, no audit

    def audit(self, hours=24, path=None):
        """Deterministic read of the last `hours` of the root trajectory: wasted wakes, failed runs, asks nobody
        touched, promises the responder made without a goal, sends that failed, helpers that died. No inference.
        Writes dream/<day>/audit.json and returns it; the skill turns each problem into a fix, an own goal, or
        a goal to raise it with Hal or Kim."""
        path = Path(path) if path else self.trajectory_path()
        since = (self.clock().astimezone(UTC) - dt.timedelta(hours=hours)).isoformat().replace("+00:00", "Z")
        out = {"day": self.day(), "since": since, "hours": hours, "trajectory": str(path) if path else None,
               "runs": {}, "problems": [], "counts": {}}
        if not path or not path.exists():
            out["problems"].append({"kind": "no-trajectory", "detail": "ROOT_TRAJ_ID/traj path unavailable; audit skipped"})
            return self._save_audit(out)
        runs, steps_by_run, run_end = {}, {}, {}
        me = os.environ.get("IDENTITY_NAME", "custos")
        replies, failed_sends, helper_failures, capped = [], [], [], []
        with path.open(encoding="utf-8", errors="replace") as f:
            for line in f:
                if '"ts"' not in line: continue
                try: st = json.loads(line)
                except ValueError: continue
                ts = st.get("ts") or ""
                if st.get("type") == "shellm-run":
                    runs[st.get("step_id")] = {"thinker": st.get("launched_by") or "?", "ts": ts, "wake": st.get("wake") or "",
                                               "max_iterations": st.get('max_iterations')}
                    if ts >= since:
                        steps_by_run.setdefault(st.get('step_id'), {'reasoning': 0, 'durable': 0, 'final': 0, 'maintenance': False, 'handoff': False, 'first_durable': None})
                    continue
                if ts < since: continue
                rid = st.get("run_id"); kind = st.get("type")
                if rid:
                    b = steps_by_run.setdefault(rid, {"reasoning": 0, "durable": 0, "final": 0, "maintenance": False, "handoff": False, "first_durable": None})
                    if kind == "reasoning": b["reasoning"] += 1
                    elif kind == 'final': b['final'] += 1
                    elif kind in {"observation", "message", "action", "thought", "idle", "merge"}:
                        b["durable"] += 1
                        if b["first_durable"] is None: b["first_durable"] = b["reasoning"]
                    if kind == 'feedback' and (st.get('content') or '').startswith('[harness maintenance]'):
                        b['maintenance'] = True
                    if kind == 'harness-handoff': b['handoff'] = True
                if kind == "run-end": run_end[rid] = {"rc": st.get("rc"), "ts": ts}
                if kind == "message" and st.get("from") == me and st.get("source") == "responder" and st.get("content"):
                    replies.append({"ts": ts, "to": st.get("to"), "reply_to": st.get("reply_to"), "text": st["content"][:200],
                                    "promise": cm.promises_work(st["content"])})
                if kind == "observation":
                    c = (st.get("content") or "")
                    if re.search(r"\b(reply-failed|not sent|failed to send|could not deliver|delivery failed)\b", c, re.I):
                        failed_sends.append({"ts": ts, "source": st.get("source"), "text": c[:200]})
                if kind == "shell-output":
                    o = (st.get("stdout") or "") + (st.get("stderr") or "")
                    if re.search(r"Helper returned nonzero|hit iteration limit|timed out 900|without FINAL|killed by watchdog", o):
                        helper_failures.append({"ts": ts, "run": (rid or "")[:8], "text": o[:160].replace("\n", " ")})
        per = {}
        out['cap_basis'] = 'Recorded max_iterations per run; otherwise current SHELLM_MAX_ITERATIONS (historical estimate).'
        out['run_details'] = []
        for rid, b in steps_by_run.items():
            t = runs.get(rid, {}).get("thinker", "?")
            row = per.setdefault(t, {"runs": 0, "rc_nonzero": 0, "no_durable": 0, "reasoning_steps": 0, "at_cap": 0,
                                     'maintenance_interrupted': 0, 'incomplete': 0, 'final_only': 0, 'failures': 0})
            row["runs"] += 1; row["reasoning_steps"] += b["reasoning"]
            rc = run_end.get(rid, {}).get('rc')
            failed = rc not in (0, None)
            interrupted = rc is not None and (b['handoff'] or (failed and b['maintenance']))
            if failed: row['rc_nonzero'] += 1
            if interrupted: row['maintenance_interrupted'] += 1
            elif failed: row['failures'] += 1
            if rc is None: row['incomplete'] += 1
            if b['final'] and not b['durable']: row['final_only'] += 1
            if rc is not None and not interrupted and not b['final'] and b['durable'] == 0:
                row['no_durable'] += 1
            recorded = runs.get(rid, {}).get('max_iterations')
            cap_source = 'run' if recorded is not None else 'current-environment-estimate'
            raw_cap = recorded if recorded is not None else os.environ.get('SHELLM_MAX_ITERATIONS')
            try: cap = int(raw_cap)
            except (TypeError, ValueError): cap = None
            if cap is not None and cap <= 0: cap = None
            at_cap = t == 'monolith' and cap is not None and b['reasoning'] >= cap
            if at_cap: row['at_cap'] += 1; capped.append(rid[:8])
            out['run_details'].append({'run_id': rid, 'thinker': t, 'rc': rc, 'reasoning_steps': b['reasoning'],
                                       'maintenance_interrupted': interrupted, 'cap': cap, 'cap_source': cap_source,
                                       'at_cap': at_cap})
        out["runs"] = per
        # Asks nobody touched: active directed tasks older than 6 h with no event after capture and no scratchpad.
        untouched = []
        try:
            for row in self.store.context(limit=100, directed_only=True)["goals"]:
                if row.get("kind") != "task": continue
                rec = self.store.find(row["goal_id"])[4]
                events = [e for e in rec.get("events", []) if "update" in e or "note" in e or "checklist" in e]
                if row.get("age_hours", 0) >= 6 and not events and not rec.get("scratchpad"):
                    untouched.append({"goal_id": row["goal_id"], "who": row.get("who"), "age_hours": row.get("age_hours"),
                                      "quick": row.get("quick", False), "summary": row.get("summary", "")[:120]})
        except Exception as e: out["problems"].append({"kind": "goal-read-failed", "detail": repr(e)[:120]})  # noqa: BLE001
        promised = [r for r in replies if r["promise"]]
        out["counts"] = {"responder_replies": len(replies), "replies_with_promise_wording": len(promised), "failed_sends": len(failed_sends),
                         "helper_failures": len(helper_failures), "untouched_asks": len(untouched)}
        for t, row in per.items():
            if row["no_durable"] >= 3 or (row["runs"] and row["no_durable"] / row["runs"] > 0.25):
                out["problems"].append({"kind": "wasted-wakes", "thinker": t, "detail": f"{row['no_durable']} of {row['runs']} runs produced no durable step"})
            if row['failures'] >= 3:
                out["problems"].append({"kind": "failed-runs", "thinker": t, "detail": f"{row['failures']} of {row['runs']} runs failed without an explicit maintenance handoff; causes require inspection"})
        if capped: out["problems"].append({"kind": "iteration-cap", "detail": "monolith runs at the cap: " + ", ".join(capped[:8])})
        for u in untouched:
            out["problems"].append({"kind": "untouched-ask", "goal_id": u["goal_id"], "who": u["who"], "quick": u["quick"],
                                    "detail": f"{u['who']}'s ask untouched for {u['age_hours']} h: {u['summary']}"})
        for r in promised:
            out["problems"].append({"kind": "promise-in-reply", "detail": f"{r['ts'][11:19]} to {r['to']}: {r['text'][:120]}"})
        for r in failed_sends[:10]: out["problems"].append({"kind": "failed-send", "detail": f"{r['ts'][11:19]} {r['source']}: {r['text'][:120]}"})
        for r in helper_failures[:10]: out["problems"].append({"kind": "helper-failure", "detail": f"{r['ts'][11:19]} run {r['run']}: {r['text']}"})
        return self._save_audit(out)

    def _save_audit(self, out):
        write_json(self.root / out["day"] / "audit.json", out)
        return out

    def _finish(self, s, status, note):
        self.journals(s)
        report_dir = self.root / s["day"]
        s["status"] = status; s["finished"] = self.stamp(); s["note"] = note
        write_json(report_dir / "session.json", s)
        missing = [r["id"] for r in s["selected"] if r["id"] not in s["reviews"]]
        lines = ["# Memory dream " + s["day"], "", "Status: " + status, "", note, "",
                 f"Inventory: {s['inventory_count']}; selected: {len(s['selected'])}; reviewed: {len(s['reviews'])}; edits: {len(s['edits'])}.", "",
                 "Change journals (prepared is not proof of application): " + ", ".join(s["edits"]), "",
                 "Unreviewed (carry forward): " + (", ".join(missing) or "none"), ""]
        for key, r in s["reviews"].items(): lines.append(f"- {key}: {r['verdict']} — {r['evidence']}")
        reflection = s.get('persona_reflection')
        lines += ['', '## Persona reflection', '',
                  json.dumps(reflection, ensure_ascii=False) if reflection else 'Not reviewed; no conclusion implied.']
        for path in s['edits']:
            change = read_json(Path(path))
            if change.get('operation') == 'persona':
                candidate = read_json(Path(change['candidate']))
                lines += ['', f"Revision {change['id']} ({change['status']}): {change['evidence']}",
                          'Replaced/retired: ' + change['replaces'],
                          'Revisit: ' + json.dumps(candidate['follow_up'], ensure_ascii=False)]
        audit = read_json(report_dir / "audit.json")
        if audit:
            lines += ["", f"## Trajectory audit (last {audit.get('hours')} h)", "",
                      "Runs: " + "; ".join(f"{t}: {r['runs']} runs, {r['no_durable']} no-durable, {r['rc_nonzero']} rc!=0" for t, r in (audit.get("runs") or {}).items()),
                      "Counts: " + json.dumps(audit.get("counts") or {}), ""]
            lines += [f"- {p_['kind']}: {p_.get('detail', '')}" for p_ in audit.get("problems") or []] or ["- no problems found"]
        atomic(report_dir / "report.md", ("\n".join(lines) + "\n").encode())
        return {"day": s["day"], "status": status, "reviewed": len(s["reviews"]), "remaining": len(missing), "report": str(report_dir / "report.md")}

    def finish(self, note):
        with self.store.lock("dream-schedule"):
            s = read_json(self.session_path())
            if not s or s["status"] not in {"running", "pending"}: raise ValueError("no unfinished dream today")
            result = self._finish(s, "complete" if len(s["reviews"]) == len(s["selected"]) else "partial", note)
        if os.environ.get("TRAJ_ID"):
            cm.append_step({"type": "observation", "source": "memory-dream", "content": "Memory dream " + result["status"] + "; " + str(result["reviewed"]) + " records reviewed, " + str(result["remaining"]) + " carried forward. Private report: " + result["report"]})
        return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('command', choices=['due','begin','inventory','status','show','revise','archive','review','review-batch','finish-preview','finish','audit',
                                    'persona-show','persona-reflect','persona-revise','persona-render'])
    p.add_argument('id', nargs='?'); p.add_argument('--expected'); p.add_argument('--body-file'); p.add_argument('--evidence', default='')
    p.add_argument('--replacement'); p.add_argument('--verdict'); p.add_argument('--note', default='')
    p.add_argument('--hours', type=int, default=24); p.add_argument('--trajectory')
    p.add_argument('--replaces'); p.add_argument('--follow-up'); p.add_argument('--identity-dir')
    p.add_argument('--decisions-file'); p.add_argument('--preview', action='store_true')
    a = p.parse_args()
    try:
        if a.command == 'persona-render':
            from custos_persona import render
            identity = a.identity_dir or os.environ.get('IDENTITY_DIR')
            if not identity: raise ValueError('identity directory required')
            print(render(identity), end=''); return 0
        d = Dream()
        if a.command == 'due': print(d.due()); return 0
        if a.command == 'begin': result=d.begin()
        elif a.command.startswith('persona-'):
            from custos_persona import Persona
            persona = Persona(d)
            if a.command == 'persona-show': result=persona.show()
            elif a.command == 'persona-reflect': result=persona.reflect(a.expected,a.verdict,a.evidence)
            else: result=persona.revise(a.expected,Path(a.body_file).read_text() if a.body_file else None,
                                       a.evidence,a.replaces,a.follow_up)
        elif a.command == 'audit': result=d.audit(hours=max(1, min(a.hours, 72)), path=a.trajectory)
        elif a.command == 'inventory': result=d.inventory()
        elif a.command == 'show':
            if not re.fullmatch(r'[0-9a-f]{8}', a.id or ''): raise ValueError('full eight-hex ID required')
            matches = [p for directory in [d.store.directory, d.store.archive_dir()] for p in directory.glob('*.md')
                       if cm.split_memory(p.read_text())[2].get('id') == a.id]
            if len(matches) != 1: raise ValueError('missing or ambiguous memory')
            print(matches[0].read_text()); return 0
        elif a.command == 'status': result=read_json(d.session_path(), {'day':d.day(),'status':'not-scheduled','config':d.config})
        elif a.command in {'revise','archive'}:
            result=d.revise(a.id,a.expected,Path(a.body_file).read_text() if a.body_file else None,a.evidence,a.command=='archive',a.replacement)
        elif a.command == 'review': result=d.review(a.id,a.expected,a.verdict,a.evidence)
        elif a.command == 'review-batch':
            if not a.decisions_file: raise ValueError('--decisions-file required')
            with open(a.decisions_file, 'rb') as f: raw = f.read(524289)
            if len(raw) > 524288: raise ValueError('review batch file too large')
            result=d.review_batch(json.loads(raw))
        elif a.command == 'finish-preview' or (a.command == 'finish' and a.preview): result=d.finish_preview()
        else: result=d.finish(a.note or 'Bounded review finished; see individual evidence and unresolved items.')
        print(json.dumps(result,ensure_ascii=False));return 0
    except (ValueError,cm.MemoryError,OSError,KeyError,TypeError) as e:
        print('custos-dream: '+str(e),file=__import__('sys').stderr);return 1

if __name__=='__main__':raise SystemExit(main())
