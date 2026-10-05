"""Read-only GitHub reconciliation -> durable, discretionary PR observations.

Pagination and scan stages survive observer deadlines. No model or outbound GitHub
calls. Baselines advance atomically with pending intake, never before it.
"""
import json
import re
import subprocess
import time
from urllib.parse import urlencode

from custos_square import APIError, canonical, digest

PREFIX = "github-prs:"
REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
_GH_STATUS = re.compile(r"\(HTTP (\d{3})\)")


def classify_gh_error(stderr, rc):
    """Map a failed `gh api` to a bounded error code from its HTTP status.

    gh reports the status on stderr as `gh: <msg> (HTTP <code>)`; the code is
    the only server-controlled fact we keep. A 404 (object hidden/renamed/
    deleted) is permanent and not worth retrying; a 429 or 5xx is transient.
    Anything unparseable stays the flat github_pr_api_failed.
    """
    m = _GH_STATUS.search(stderr or "")
    if m and rc:
        code = int(m.group(1))
        if code == 404:
            return "github_pr_not_found"
        if code == 429:
            return "github_pr_rate_limited"
        if 500 <= code <= 599:
            return "github_pr_server_error"
    return "github_pr_api_failed"


RETRYABLE = frozenset(("github_pr_server_error", "github_pr_rate_limited",
                       "github_pr_timeout", "github_pr_api_failed"))


def retry_warranted(code):
    """True when a recorded error is transient and a retry can clear it."""
    return code in RETRYABLE

# A non-retryable failure (e.g. a 404 on a hidden/renamed object) is probed on
# this long quarantine backoff instead of the 15-min transient one, so a dead
# org stops burning a scan every cycle. 6h = two full rotations (~3h each).
PERMANENT_RETRY = 6 * 3600
STAGES = ("comments", "reviews", "review_comments", "timeline", "checks", "statuses")


class Budget(Exception):
    pass


class API:
    def __init__(self, seconds=70, calls=60):
        self.deadline = time.monotonic() + seconds
        self.calls = calls

    def get(self, endpoint, **params):
        if self.calls <= 0 or time.monotonic() >= self.deadline:
            raise Budget()
        self.calls -= 1
        endpoint += ("&" if "?" in endpoint else "?") + urlencode(params) if params else ""
        try:
            result = subprocess.run(["gh", "api", "--method", "GET", endpoint],
                capture_output=True, text=True, timeout=min(15, max(1, self.deadline-time.monotonic())))
        except subprocess.TimeoutExpired:
            raise APIError("github_pr_timeout") from None
        # Never relay gh stderr, credentials or server-controlled errors to memory;
        # keep only the bounded HTTP-status class (404 vs 429 vs 5xx vs unparseable).
        if result.returncode:
            raise APIError(classify_gh_error(result.stderr, result.returncode))
        if len(result.stdout) > 8 * 1024 * 1024:
            raise APIError("github_pr_response_too_large")
        return json.loads(result.stdout)


def target(repo, number):
    if not isinstance(repo, str) or not REPO.fullmatch(repo) or type(number) is not int or number < 1:
        raise APIError("github_pr_target_invalid")
    return repo + "#" + str(number)


def pr_projection(pr):
    if pr.get("base", {}).get("repo", {}).get("private") is not False:
        raise APIError("github_pr_not_public")
    sha = pr.get("head", {}).get("sha", "")
    if not re.fullmatch(r"[a-f0-9]{40,64}", sha):
        raise APIError("github_pr_head_invalid")
    return {"head": sha, "base_ref": pr["base"]["ref"], "state": pr["state"],
        "draft": pr.get("draft", False), "merged": pr.get("merged", False),
        "title": pr.get("title", "")[:300], "body_hash": digest(pr.get("body") or ""),
        "labels": sorted(x["name"] for x in pr.get("labels", [])),
        "assignees": sorted(x["login"] for x in pr.get("assignees", [])),
        "requested_reviewers": sorted(x["login"] for x in pr.get("requested_reviewers", [])),
        "requested_teams": sorted(x["slug"] for x in pr.get("requested_teams", []))}


def event_projection(row):
    # Fingerprint the full public record: edits/reactions/conclusions as well as
    # newly added IDs. Keep compact evidence pointers; fetch text only at review.
    return {"hash": digest(canonical(row)),
        "actor": (row.get("user") or row.get("actor") or {}).get("login", ""),
        "event": row.get("event") or row.get("state") or row.get("conclusion") or "changed",
        "url": row.get("html_url") or row.get("url") or "",
        "body_excerpt": (row.get("body") or "")[:2000],
        "body_truncated": len(row.get("body") or "") > 2000,
        "reactions": row.get("reactions", {})}


class Monitor:
    def __init__(self, observer, api=None):
        self.observer, self.store = observer, observer.store
        self.api = api or API()
        self.config = observer.config["github_prs"]
        self.login = self.config.get("author", "custos-1f916")
        if not re.fullmatch(r"[A-Za-z0-9-]+", self.login):
            raise APIError("github_pr_author_invalid")
        self.repo = self.config.get("review_repo", "1f916-ai/1f916")
        target(self.repo, 1)
        self.now = observer.now

    def inventory(self, repo, number, role):
        key = target(repo, number)
        inventory = self.store.get(PREFIX + "inventory", {})
        row = inventory.setdefault(key, {"repo": repo, "number": number, "roles": [], "last_scan": 0})
        if role not in row["roles"]:
            row["roles"].append(role)
        self.store.put(PREFIX + "inventory", inventory)

    def discover(self):
        state = self.store.get(PREFIX + "discovery", {"stage": "authored", "page": 1,
            "since": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(self.now))})
        if state.get("next", 0) > self.now:
            return
        self.store.put(PREFIX + "discovery", state)
        while True:
            page = state["page"]
            if state["stage"] == "authored":
                data = self.api.get("search/issues", q="is:pr is:public author:"+self.login,
                                    sort="created", order="asc", per_page=100, page=page)
                if data.get("incomplete_results") or data.get("total_count", 0) > 1000:
                    raise APIError("github_pr_discovery_incomplete")
                rows = data["items"]
                for row in rows:
                    match = re.fullmatch(r"https://api.github.com/repos/([^/]+/[^/]+)", row["repository_url"])
                    if not match:
                        raise APIError("github_pr_repository_invalid")
                    self.inventory(match[1], row["number"], "authored")
            else:
                # Full all-state pagination also catches opened-and-closed PRs
                # between polls. Historical closed PRs establish a quiet baseline.
                try:
                    rows = self.api.get("repos/"+self.repo+"/pulls", state="all", sort="created",
                                        direction="desc", per_page=100, page=page)
                except APIError as exc:
                    if exc.code != "github_pr_not_found":
                        raise
                    # A dead review_repo 404s forever; skip its stage so the
                    # authored search keeps running. The unblocking event is
                    # unchanged: the repo returns 200 again, which the next
                    # cycle's reviews stage will see.
                    rows = []
                for row in rows:
                    if row["state"] == "open" or row["created_at"] >= state["since"]:
                        self.inventory(self.repo, row["number"], "review")
            if len(rows) == 100:
                state["page"] += 1
            elif state["stage"] == "authored":
                state.update(stage="reviews", page=1)
            else:
                state.update(stage="authored", page=1, next=self.now+900, last_success=self.now)
                self.store.put(PREFIX + "discovery", state)
                return
            self.store.put(PREFIX + "discovery", state)

    def scan(self, key, entry):
        storage = PREFIX + "pr:" + key
        state = self.store.get(storage, {})
        if state.get("pending"):
            return
        base = "repos/"+entry["repo"]
        number = str(entry["number"])
        scan = state.get("scan")
        if not scan:
            pr = self.api.get(base+"/pulls/"+number)
            scan = {"pr": pr_projection(pr), "stage": 0, "page": 1, "events": {}}
            state["scan"] = scan
            self.store.put(storage, state)
        while scan["stage"] < len(STAGES):
            kind = STAGES[scan["stage"]]
            paths = {"comments": "/issues/"+number+"/comments", "reviews": "/pulls/"+number+"/reviews",
                "review_comments": "/pulls/"+number+"/comments", "timeline": "/issues/"+number+"/timeline",
                "checks": "/commits/"+scan["pr"]["head"]+"/check-runs",
                "statuses": "/commits/"+scan["pr"]["head"]+"/statuses"}
            data = self.api.get(base+paths[kind], per_page=100, page=scan["page"])
            rows = data["check_runs"] if kind == "checks" else data
            if not isinstance(rows, list):
                raise APIError("github_pr_page_invalid")
            for row in rows:
                identity = str(row.get("id") or row.get("node_id") or digest(canonical(row)))
                scan["events"][kind+":"+identity] = event_projection(row)
            if len(rows) == 100:
                scan["page"] += 1
            else:
                scan["stage"] += 1
                scan["page"] = 1
            state["scan"] = scan
            self.store.put(storage, state)
        # Re-read metadata after a possibly multi-tick scan. A new head invalidates
        # old-head checks; restart without advancing the durable baseline.
        latest = pr_projection(self.api.get(base+"/pulls/"+number))
        if latest["head"] != scan["pr"]["head"]:
            state.pop("scan")
            self.store.put(storage, state)
            return
        snapshot = {"pr": latest, "events": scan["events"]}
        old = state.get("snapshot")
        changes = []
        evidence = []
        if old:
            if old["pr"] != latest:
                changes.append("PR metadata/head/state changed")
            for event in sorted(set(old["events"]) | set(snapshot["events"])):
                before, after = old["events"].get(event), snapshot["events"].get(event)
                if before != after and ((after or before).get("actor") != self.login or
                        (before and after and before.get("reactions") != after.get("reactions"))):
                    changes.append(event + (" deleted" if after is None else " added/edited"))
                    evidence.append({"event": event, "before": before, "after": after})
        # A review is work only while the PR is open, and an authored PR that is already
        # closed or merged at initial inventory is a quiet baseline, not a task: on
        # 2026-09-17 eight of the first eighteen goals were for settled PRs (one merged a
        # week earlier), costing a third of the day's review inference. After the baseline,
        # any external change on an authored PR (a comment on a merged one) is feedback.
        open_pr = latest["state"] == "open"
        review = "review" in entry["roles"] and open_pr and (old is None or
            (old["pr"]["head"], old["pr"]["base_ref"], old["pr"]["draft"], old["pr"]["body_hash"], old["pr"]["state"]) !=
            (latest["head"], latest["base_ref"], latest["draft"], latest["body_hash"], latest["state"]))
        feedback = "authored" in entry["roles"] and ((old is None and open_pr) or (old is not None and bool(changes)))
        state.pop("scan", None)
        state["snapshot"] = snapshot
        state["last_success"] = self.now
        if review or feedback:
            sequence = state.get("sequence", 0)+1
            state["sequence"] = sequence
            summary = {"pr": key, "head": latest["head"], "state": latest["state"],
                "review": review, "authored_feedback": feedback, "initial_inventory": old is None,
                "change_count": len(changes), "changes": changes[:18]}
            state["pending"] = {"id": "github-pr:"+key+":"+str(sequence), "summary": summary, "observed_at": self.now,
                "evidence": {"before_pr": old["pr"] if old else None, "after_pr": latest,
                    "events": evidence if old else [{"event": k, "before": None, "after": v} for k, v in snapshot["events"].items()]}}
        # One sqlite value commits the baseline AND its pending work atomically.
        self.store.put(storage, state)
        inventory = self.store.get(PREFIX+"inventory", {})
        inventory[key]["last_scan"] = self.now
        inventory[key].pop("error", None)
        inventory[key].pop("retry_at", None)
        self.store.put(PREFIX+"inventory", inventory)

    def deliver(self, key, entry):
        storage = PREFIX+"pr:"+key
        state = self.store.get(storage, {})
        pending = state.get("pending")
        if not pending:
            return False
        url = "https://github.com/"+entry["repo"]+"/pull/"+str(entry["number"])
        self.store.put(PREFIX+"evidence:"+pending["id"], {"summary": pending["summary"], **pending["evidence"]})
        attention = state.get("attention", {})
        keep_age = (attention.get("summary", {}).get("head") == pending["summary"]["head"]
                    and not self.store.get(PREFIX+"disposition:"+attention.get("id", "")))
        state["attention"] = {"id": pending["id"], "summary": pending["summary"],
            "first_seen": attention["first_seen"] if keep_age else pending.get("observed_at", self.now),
            "updated_at": pending.get("observed_at", self.now)}
        # The queue and evidence survive even if this tick has no signal budget.
        self.store.put(storage, state)
        if not self.observer.emit(pending["id"],
                "GitHub PR observation (discretionary; no goal): "+key+"; head "+pending["summary"]["head"]+
                "; evidence "+pending["id"]+". Choose whether/when to review; load custos-pr-review.", url):
            return False
        # Native append and emit dedup make replay after any interrupted write safe.
        state["last_delivery"] = pending["id"]
        state.pop("pending")
        self.store.put(storage, state)
        return True

    def run(self):
        failures = []
        try:
            self.discover()
            self.store.put(PREFIX+"discovery_error", None)
        except Budget:
            pass
        except (APIError, ValueError, KeyError, TypeError) as exc:
            self.store.put(PREFIX+"discovery_error", "discovery:"+getattr(exc, "code", type(exc).__name__))
        inventory = self.store.get(PREFIX+"inventory", {})
        deliveries = 0
        for key, entry in sorted(inventory.items(), key=lambda x: (x[1].get("last_attempt", 0), x[0])):
            if deliveries < 3 and self.deliver(key, entry):
                deliveries += 1
        for key, entry in sorted(inventory.items(), key=lambda x: (x[1].get("last_attempt", 0), x[0])):
            if entry.get("retry_at", 0) > self.now:
                continue
            # A transient failure is not a rotation attempt: restore the prior
            # last_attempt so the 15-min retry_at backoff (not the ~3h full
            # rotation) governs the retry. A failed entry otherwise sinks to the
            # back of the (last_attempt, key) order and its error sits in the
            # health signature until the rotation reaches it again.
            previous_attempt = entry.get("last_attempt", 0)
            try:
                current = self.store.get(PREFIX+"inventory", {})
                current[key]["last_attempt"] = self.now
                self.store.put(PREFIX+"inventory", current)
                self.scan(key, entry)
                if deliveries < 3 and self.deliver(key, entry):
                    deliveries += 1
            except Budget:
                break
            except (APIError, ValueError, KeyError, TypeError) as exc:
                current = self.store.get(PREFIX+"inventory", {})
                code = getattr(exc, "code", type(exc).__name__)
                # A permanent failure (e.g. a 404 on a hidden/renamed object) is
                # probed on the long quarantine backoff, not the 15-min transient
                # one, so a dead org stops burning a scan every cycle. The
                # unblocking event is unchanged: the target returns 200 again.
                current[key]["retry_at"] = self.now + (900 if retry_warranted(code) else PERMANENT_RETRY)
                current[key]["last_error"] = self.now
                current[key]["error"] = code
                current[key]["last_attempt"] = previous_attempt
                self.store.put(PREFIX+"inventory", current)
        inventory = self.store.get(PREFIX+"inventory", {})
        failures = [key+":"+entry["error"] for key, entry in inventory.items() if entry.get("error")]
        if self.store.get(PREFIX+"discovery_error"):
            failures.append(self.store.get(PREFIX+"discovery_error"))
        previous = self.store.get(PREFIX+"health", {})
        signature = digest(sorted(failures))
        episode = previous.get("episode", 0)+(signature != previous.get("signature"))
        alerted = previous.get("alerted", False) if signature == previous.get("signature") else False
        if not alerted and (failures or previous.get("failures")):
            transient = [f for f in failures if retry_warranted(f.rsplit(":", 1)[-1])]
            permanent = [f for f in failures if not retry_warranted(f.rsplit(":", 1)[-1])]
            detail = ("retrying " + ", ".join(transient)[:1500] if transient
                      else "not retrying " + ", ".join(permanent)[:1500]) if failures else ""
            alerted = self.observer.emit("github-pr-health:"+str(episode),
                "GitHub PR monitor: " + (("partial coverage; " + detail)
                    if failures else "coverage recovered; scans continuing"))
        self.store.put(PREFIX+"health", {"checked_at": self.now, "tracked": len(inventory),
            "failures": failures, "signature": signature, "episode": episode, "alerted": alerted,
            "pending": sum(bool(self.store.get(PREFIX+"pr:"+k, {}).get("pending")) for k in inventory)})



def poll(observer):
    Monitor(observer).run()


def queue(store, now=None, offset=0, limit=10):
    """A read-only view of attention, not a second goal scheduler."""
    now = time.time() if now is None else now
    items = []
    for key, entry in (store.get(PREFIX+"inventory", {}) or {}).items():
        state = store.get(PREFIX+"pr:"+key, {})
        attention = state.get("attention")
        if not attention or store.get(PREFIX+"disposition:"+attention["id"]):
            continue
        pr = state.get("snapshot", {}).get("pr", {})
        summary = attention["summary"]
        # Closing a third-party PR ends its review opportunity, not authored feedback.
        if pr.get("state") == "closed" and not summary.get("authored_feedback"):
            continue
        age = max(0, now-attention["first_seen"])
        items.append({**attention, "age_hours": round(age/3600, 1), "older_than_day": age >= 86400,
            "current_head": pr.get("head"), "current_state": pr.get("state"),
            "last_scan": state.get("last_success"), "legacy_goal": state.get("goal_id"),
            "source_url": "https://github.com/"+entry["repo"]+"/pull/"+str(entry["number"])})
    items.sort(key=lambda x: (x["first_seen"], x["id"]))
    return {"mode": "observational", "total": len(items),
        "older_than_day": sum(x["older_than_day"] for x in items),
        "offset": offset, "items": items[offset:offset+limit],
        "health": store.get(PREFIX+"health", {"unavailable": True})}


def context(store, now=None):
    view = queue(store, now, limit=8)
    health = view["health"]
    lines = ["PR observations: %d waiting, %d older than a day. No automatic goals or review quota; "
             "at an act wake notice this queue and choose whether/which to review, alongside make/explore."
             % (view["total"], view["older_than_day"])]
    if health.get("unavailable") or health.get("failures"):
        lines.append("Monitor coverage is incomplete/unavailable; inspect --queue health before calling the queue quiet.")
    checked = health.get("checked_at", 0)
    if checked and (time.time() if now is None else now)-checked > 1800:
        lines.append("Monitor snapshot is older than 30 minutes; inspect coverage health.")
    for row in view["items"]:
        lines.append("- %s head %s, age %.1fh%s; batch %s" % (row["summary"]["pr"],
            row["summary"]["head"][:12], row["age_hours"], " (older than a day)" if row["older_than_day"] else "", row["id"]))
    lines.append("Read/page: python3 /opt/custos/current/renewal/custos_github_prs.py --queue --offset 0 --limit 10. Load custos-pr-review when choosing a review.")
    return "\n".join(lines)


def disposition(store, batch, head, report, kind):
    """Record a chosen review against an immutable batch; never clear newer activity."""
    from pathlib import Path
    if kind not in {"reviewed", "no-action"}:
        raise ValueError("invalid disposition")
    evidence = store.get(PREFIX+"evidence:"+batch)
    if not evidence or evidence["summary"]["head"] != head:
        raise ValueError("batch and full head must match retained evidence")
    path = Path(report).resolve(strict=True)
    raw = path.read_bytes()
    if not raw or len(raw) > 1024*1024 or head not in raw.decode():
        raise ValueError("retain a report containing the full reviewed head")
    import hashlib
    result = {"batch": batch, "head": head, "disposition": kind,
        "report": str(path), "sha256": hashlib.sha256(raw).hexdigest()}
    key = PREFIX+"disposition:"+batch
    # Separate immutable receipt key, including across concurrent acknowledgments.
    # The observer alone owns PR snapshot/attention keys.
    with store.db:
        store.db.execute("INSERT OR IGNORE INTO state VALUES (?,?)", (key, canonical(result)))
    if store.get(key) != result:
        raise ValueError("batch already has a different disposition; retain the original receipt")
    return result


def retire_automatic_goals(store, memory, apply=False):
    """Explicit upgrade: retain evidence, then abandon only authenticated old feed goals.

    Real Signal/square asks and self-chosen work are never candidates. Run after
    deploying observation intake; the caller serializes this with the observer.
    """
    import datetime as dt
    results = []
    for _, _, _, fields, record in list(memory.files()):
        if not record or record["status"] != "active":
            continue
        origin = record["origin"]
        match = re.fullmatch(r"github-pr:([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([1-9][0-9]*):([1-9][0-9]*)", origin["request_id"])
        if (not match or origin.get("sender") != "operator:github-pr-review"
                or origin.get("authority") != "operator" or record.get("trigger_step")):
            continue
        repo, number, _ = match.groups()
        url = "https://github.com/"+repo+"/pull/"+number
        if origin.get("source_url") != url:
            continue
        key = target(repo, int(number)); storage = PREFIX+"pr:"+key
        state = store.get(storage, {})
        batch = state.get("last_delivery") or origin["request_id"]
        evidence = store.get(PREFIX+"evidence:"+batch)
        if not evidence:
            raise ValueError("missing legacy observation evidence for "+fields["id"])
        reason = ("Hal changed automatic PR review obligations to discretionary observations on 2026-09-24. "
                  "Obligation retired, not a claim of completed review. Notes/checklists and reports remain here; "
                  "queue evidence: "+batch+". Choose whether/when to continue via custos-pr-review.")
        results.append({"goal_id": fields["id"], "batch": batch, "reason": reason})
        if apply:
            if not state.get("attention"):
                state["attention"] = {"id": batch, "summary": evidence["summary"],
                    "first_seen": dt.datetime.fromisoformat(record["received_at"].replace("Z", "+00:00")).timestamp(),
                    "updated_at": state.get("last_success", time.time())}
                store.put(storage, state)
            store.put(PREFIX+"retired-goal:"+fields["id"], results[-1])
            memory.complete({"goal_id": fields["id"], "disposition": "abandoned", "evidence": reason})
    return results


def main():
    import argparse
    import sqlite3
    from custos_square import STATE, Store
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--evidence", help="github-pr:OWNER/REPO#NUMBER:SEQUENCE from the queue")
    mode.add_argument("--queue", action="store_true")
    mode.add_argument("--context", action="store_true")
    mode.add_argument("--ack", help="record disposition for this exact batch")
    parser.add_argument("--head")
    parser.add_argument("--report")
    parser.add_argument("--disposition", choices=["reviewed", "no-action"], default="reviewed")
    parser.add_argument("--offset", type=int, default=0)
    parser.add_argument("--limit", type=int, default=10)
    args = parser.parse_args()
    offset, limit = max(0, args.offset), min(20, max(1, args.limit))
    if args.ack:
        if not args.head or not args.report: parser.error("--ack requires --head and --report")
        store = Store()
        try: print(canonical(disposition(store, args.ack, args.head, args.report, args.disposition)))
        finally: store.db.close()
        return
    with sqlite3.connect((STATE/"observations.sqlite").as_uri()+"?mode=ro", uri=True) as db:
        class ReadOnly:
            def get(self, key, default=None):
                row = db.execute("SELECT value FROM state WHERE key=?", (key,)).fetchone()
                return json.loads(row[0]) if row else default
        store = ReadOnly()
        db.execute("BEGIN")  # queue/health from one consistent read snapshot
        if args.context:
            print(context(store)); return
        if args.queue:
            print(canonical(queue(store, offset=offset, limit=limit))); return
        value = store.get(PREFIX+"evidence:"+args.evidence if args.evidence else PREFIX+"health", {"unavailable": True})
        if args.evidence and "events" in value:
            events = value["events"]
            value.update(total_events=len(events), offset=offset, events=events[offset:offset+limit])
        print(canonical(value))


if __name__ == "__main__":
    main()
