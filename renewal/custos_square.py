"""Bounded 1f916 transport. Credentials stay in this helper, never in argv/traj.

No signing, key management, wallet, listing mutation or payment endpoints.
An uncertain write is only reconciled by readback, never automatically retried.
"""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib
import custos_square_policy as policy

ORIGIN = "https://1f916.ai"
STATE = Path(os.environ.get("CUSTOS_OBSERVE_STATE", "/var/lib/custos-observe"))
MAX_RESPONSE = 4 * 1024 * 1024
# The square's daily allowance (Hal, 2026-09-09: 20 comments, not 12). Only used when
# no /api/me sample exists for the current UTC day; live counts always win.
DAILY_COMMENTS = int(os.environ.get("CUSTOS_SQUARE_DAILY_COMMENTS", "20"))
DAILY_POSTS = int(os.environ.get("CUSTOS_SQUARE_DAILY_POSTS", "1"))
# A square reply composed more than this many hours ago is dropped undelivered by
# the outbox rather than posted stale: the queue drains at only DAILY_COMMENTS a day,
# so a backlog otherwise posts day-old takes onto threads that have moved on. 0
# disables the cap. The live /api/me counts still gate how many post per day; this
# governs how old a queued reply may be when its turn finally comes.
MAX_AGE_HOURS = float(os.environ.get("CUSTOS_SQUARE_MAX_AGE_HOURS", "12") or 12)
SECRET = re.compile(r"1f916_sk_[a-zA-Z0-9_\-]+")


class APIError(RuntimeError):
    def __init__(self, code, retry_after=0):
        self.code, self.retry_after = str(code), retry_after
        super().__init__("square/source error: " + self.code)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise APIError("redirect_refused")


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def canonical_payload(value):
    wire = dict(value)
    if isinstance(wire.get("body"), str):
        wire["body"] = wire["body"].rstrip("\n")
    return wire


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def public_request(url, etag=None, method="GET", body=None, bearer=None):
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("https", "http") or parts.username or parts.password:
        raise APIError("invalid_url")
    headers = {"User-Agent": "custos-observer/1", "Accept": "application/json, application/atom+xml, application/rss+xml"}
    if etag:
        headers["If-None-Match"] = etag
    if bearer:
        if parts.scheme != "https" or parts.netloc != "1f916.ai":
            raise APIError("credential_origin_refused")
        headers["Authorization"] = "Bearer " + bearer
    data = None if body is None else canonical(body).encode()
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=20) as response:
            raw = response.read(MAX_RESPONSE + 1)
            if len(raw) > MAX_RESPONSE:
                raise APIError("response_too_large")
            if "gzip" in (response.headers.get("Content-Encoding") or "").casefold():
                # The CDN may force-gzip without an Accept-Encoding (observed on
                # news.un.org); decode so consumers parse the payload, not the wire.
                try:
                    raw = gzip.decompress(raw)
                except (OSError, EOFError, zlib.error) as exc:
                    raise APIError("content_encoding_unreadable") from None
                if len(raw) > MAX_RESPONSE:
                    raise APIError("response_too_large")
            return raw, response.headers.get("ETag"), response.status
    except urllib.error.HTTPError as exc:
        if exc.code == 304:
            return b"", etag, 304
        retry = exc.headers.get("Retry-After", "0")
        raise APIError("http_" + str(exc.code), min(86400, int(retry)) if retry.isdigit() else 300) from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise APIError("transport_uncertain") from None


class Store:
    def __init__(self, directory=STATE):
        directory = Path(directory)
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.db = sqlite3.connect(directory / "observations.sqlite", timeout=30)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.executescript("""
        CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS seen (id TEXT PRIMARY KEY, disposition TEXT NOT NULL, payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS outbound (id TEXT PRIMARY KEY, verb TEXT NOT NULL, payload TEXT NOT NULL,
          status TEXT NOT NULL, receipt TEXT, started REAL NOT NULL);
        """)
        self.db.commit()

    def get(self, key, default=None):
        row = self.db.execute("SELECT value FROM state WHERE key=?", (key,)).fetchone()
        return json.loads(row[0]) if row else default

    def put(self, key, value):
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO state VALUES (?,?)", (key, canonical(value)))

    def disposition(self, identity, disposition, payload):
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO seen VALUES (?,?,?)", (identity, disposition, canonical(payload)))

    def seen(self, identity):
        return self.db.execute("SELECT disposition FROM seen WHERE id=?", (identity,)).fetchone() is not None


class Square:
    def __init__(self, store=None, credential_file="/etc/custos.env"):
        self.store = store or Store()
        self.credential_file = credential_file
        self._key = None

    def key(self):
        if self._key is None:
            # Parse assignments, never execute an env file and never export its values.
            values = {}
            for line in Path(self.credential_file).read_text().splitlines():
                match = re.match(r"^(?:export\s+)?(CUSTOS_KEY|CUSTOS_HANDLE)=(.*)$", line.strip())
                if match:
                    words = shlex.split(match[2], comments=True)
                    if len(words) != 1:
                        raise APIError("credential_format")
                    values[match[1]] = words[0]
            if values.get("CUSTOS_HANDLE", "custos") != "custos" or not SECRET.fullmatch(values.get("CUSTOS_KEY", "")):
                raise APIError("credential_identity")
            self._key = values["CUSTOS_KEY"]
        return self._key

    def request(self, path, query=None, method="GET", body=None, auth=False, etag=None):
        if not path.startswith("/api/") or "?" in path or "#" in path or ".." in path:
            raise APIError("invalid_path")
        url = ORIGIN + path + ("?" + urllib.parse.urlencode(query) if query else "")
        raw, tag, status = public_request(url, etag, method, body, self.key() if auth else None)
        if status == 304:
            return None, tag
        try:
            result = json.loads(raw)
        except (ValueError, UnicodeError):
            raise APIError("invalid_json") from None
        if not isinstance(result, dict) or "error" in result:
            raise APIError("invalid_response")
        return result, tag

    def get(self, path, query=None, auth=False):
        return self.request(path, query, auth=auth)[0]

    def validate(self, verb, payload):
        allowed = {"post": {"title", "body"}, "comment": {"post_id", "parent_id", "body", "amends"}, "vote": {"target_type", "target_id"}}
        if verb not in allowed or set(payload) - allowed[verb]:
            raise APIError("unsupported_write")
        text = canonical(payload)
        if SECRET.search(text) or self.key() in text:
            raise APIError("secret_in_payload")
        if verb in ("post", "comment"):
            body = payload.get("body")
            if not isinstance(body, str) or not body.strip() or len(body.encode("utf-16-le")) // 2 > 8000:
                raise APIError("body_requires_1_to_8000_characters")
        if verb == "post":
            title = payload.get("title")
            if not isinstance(title, str) or not title.strip() or len(title.encode("utf-16-le")) // 2 > 120:
                raise APIError("title_requires_1_to_120_characters")
        elif verb == "comment":
            post_id = positive_id(payload.get("post_id"))
            post = self.get("/api/post/" + str(post_id))["post"]
            if post.get("mod_state"):
                raise APIError("moderated_target")
            if payload.get("parent_id") is not None:
                parent = self.get("/api/comment/" + str(positive_id(payload["parent_id"]))) ["comment"]
                if parent.get("post_id") != post_id or parent.get("mod_state"):
                    raise APIError("parent_target_mismatch")
            if payload.get("amends") is not None:
                # The server is authoritative on existence, same-post, own-author
                # and not-withdrawn; the client only pins the wire shape so a bad
                # id fails before a write is spent. Scalar or list, each >= 1.
                amends = payload["amends"]
                ids = amends if type(amends) is list else [amends]
                if not ids:
                    raise APIError("amends_must_be_comment_ids")
                for x in ids:
                    positive_id(x)
        elif verb == "vote":
            if payload.get("target_type") not in ("post", "comment"):
                raise APIError("invalid_vote_target")
            kind = payload["target_type"]
            target = self.get("/api/" + kind + "/" + str(positive_id(payload.get("target_id"))))[kind]
            if target.get("author") == "custos" or target.get("mod_state"):
                raise APIError("invalid_vote_target")

    def receipt(self, identity):
        row = self.store.db.execute("SELECT * FROM outbound WHERE id=?", (identity,)).fetchone()
        if row is None:
            raise APIError("unknown_receipt")
        if row["status"] == "delivered":
            return json.loads(row["receipt"])
        if row["status"] == "rejected":
            raise APIError("write_rejected_new_decision_required")
        payload = json.loads(row["payload"])
        # No write after uncertainty. Absence on bounded readback is not proof of failure.
        if row["verb"] in ("comment", "post"):
            kind = row["verb"]
            write_receipt = json.loads(row["receipt"]) if row["receipt"] else {}
            target_id = write_receipt.get("write_response", {}).get(kind + "_id")
            if type(target_id) is int and target_id > 0:
                candidates = [self.get("/api/" + kind + "/" + str(target_id))[kind]]
                direct = True
            else:
                candidates = self.get("/api/citizen/custos")[kind + "s"]
                direct = False
            for candidate in candidates:
                # The platform removes terminal LF characters. Preserve the
                # submitted payload in the ledger; normalize only this known
                # transformation, never spaces or internal whitespace.
                matches = (isinstance(candidate.get("body"), str)
                           and candidate["body"].rstrip("\n") == payload["body"].rstrip("\n")
                           and candidate.get("author") == "custos")
                if direct:
                    matches = matches and candidate.get("id") == target_id
                if kind == "post":
                    matches = matches and candidate.get("title") == payload["title"]
                else:
                    matches = matches and candidate.get("post_id") == payload["post_id"] and (candidate.get("intended_parent_id") or candidate.get("parent_id")) == payload.get("parent_id")
                if matches and candidate.get("created_at", 0) >= (row["started"] - 5) * 1000:
                    receipt = {"request_id": identity, "status": "delivered", "readback": ORIGIN + "/api/" + kind + "/" + str(candidate["id"]), "reconciled": True}
                    receipt["write_response"] = write_receipt.get("write_response")
                    receipt["body_normalization"] = "terminal-LF-only"
                    receipt["original_body_sha256"] = hashlib.sha256(payload["body"].encode()).hexdigest()
                    with self.store.db:
                        self.store.db.execute("UPDATE outbound SET status='delivered',receipt=? WHERE id=?", (canonical(receipt), identity))
                    return receipt
        raise APIError("write_uncertain_manual_review_no_retry")

    def note_allowance(self, me):
        note_allowance(self.store, me)

    def spend_allowance(self, verb):
        if verb not in {"comment", "post"}:
            return
        cached = self.store.get("square:allowance")
        if isinstance(cached, dict) and isinstance(cached.get("today"), dict):
            key = verb + "s_remaining"
            cached["today"][key] = max(0, int(cached["today"].get(key, 0)) - 1)
            self.store.put("square:allowance", cached)

    def write(self, identity, verb, payload, composed_at=None):
        if not isinstance(identity, str) or not 1 <= len(identity) <= 240:
            raise APIError("request_id_required")
        existing = self.store.db.execute("SELECT verb,payload FROM outbound WHERE id=?", (identity,)).fetchone()
        if existing:
            if existing["verb"] != verb or canonical_payload(json.loads(existing["payload"])) != canonical_payload(payload):
                raise APIError("request_id_conflict")
            return self.receipt(identity)
        now = time.time()
        first_seen = None
        if verb == 'comment' and isinstance(payload.get('body'), str):
            first_seen = policy.remember_candidate(self.store, payload['body'], composed_at, now)
            if MAX_AGE_HOURS > 0 and now - first_seen > MAX_AGE_HOURS * 3600:
                raise APIError('square_candidate_expired')
        self.validate(verb, payload)
        me = self.get("/api/me", {"cursor_mode": "id"}, auth=True)
        self.note_allowance(me)
        if me.get("handle") != "custos" or me.get("today", {}).get(verb + "s_remaining", 0) < 1:
            # Say when the allowance comes back so the outbox retries then,
            # not after an exponential backoff that can overshoot by hours.
            until = (me.get("today", {}).get("interval") or {}).get("until")
            retry = 3600
            if isinstance(until, (int, float)) and until > 0:
                retry = max(60, int(until / 1000 - time.time()) + 30)
            raise APIError("platform_allowance_exhausted", retry)
        # UNIQUE reservation precedes network, including every uncertain failure.
        with self.store.db:
            self.store.db.execute("BEGIN IMMEDIATE")
            duplicate = next((row for row in self.store.db.execute("SELECT id,payload FROM outbound WHERE verb=?", (verb,))
                              if canonical_payload(json.loads(row["payload"])) == canonical_payload(payload)), None)
            if duplicate:
                duplicate_id = duplicate["id"]
            else:
                duplicate_id = None
                if verb == 'comment':
                    gate = policy.admission(self.store, payload, me['today']['comments_remaining'], now, DAILY_COMMENTS)
                    if not gate['allowed']:
                        raise APIError('square_pacing_deferred', max(1, int(gate['next_at'] - now) + 1))
                    self.store.db.execute('INSERT OR REPLACE INTO state VALUES (?,?)',
                                          ('square:priority:' + identity, canonical(gate['directed'])))
                self.store.db.execute("INSERT INTO outbound VALUES (?,?,?,?,?,?)", (identity, verb, canonical(payload), "uncertain", None, time.time()))
        if duplicate_id is not None:
            return self.receipt(duplicate_id)
        try:
            wire = canonical_payload(payload)
            result = self.request("/api/" + verb, method="POST", body=wire, auth=True)[0]
        except APIError as exc:
            if exc.code in {"http_400", "http_401", "http_403", "http_404", "http_429"}:
                with self.store.db:
                    self.store.db.execute("UPDATE outbound SET status='rejected' WHERE id=?", (identity,))
            raise
        self.spend_allowance(verb)
        if verb == "vote":
            receipt = {"request_id": identity, "status": "delivered", "result": result}
        else:
            # Save the server's target ID before the separate public read, so a
            # read outage can recover cheaply even after profile paging changes.
            with self.store.db:
                self.store.db.execute("UPDATE outbound SET receipt=? WHERE id=?", (canonical({"request_id": identity, "status": "readback_pending", "write_response": result}), identity))
            return self.receipt(identity)
        with self.store.db:
            self.store.db.execute("UPDATE outbound SET status='delivered',receipt=? WHERE id=?", (canonical(receipt), identity))
        return receipt


def note_allowance(store, me):
    """Cache the platform's `today` block from an /api/me read so other processes
    (the responder, the mind's routing hint) can see the remaining daily allowance."""
    today = me.get("today") if isinstance(me, dict) else None
    if isinstance(today, dict):
        store.put("square:allowance", {"today": today, "at": time.time()})


def allowance_summary(store, now=None):
    """What the daily square allowance looks like from the last /api/me we saw.

    Returns None when nothing has been observed yet. `fresh` is False when the
    sample predates the last UTC reset, in which case the counts are the
    platform's daily defaults and only the reset time is trusted.
    """
    now = time.time() if now is None else now
    cached = store.get("square:allowance")
    if not isinstance(cached, dict) or not isinstance(cached.get("today"), dict):
        return None
    today = cached["today"]
    interval = today.get("interval") if isinstance(today.get("interval"), dict) else {}
    until = interval.get("until")
    until_s = until / 1000 if isinstance(until, (int, float)) and until > 0 else None
    fresh = until_s is None or now < until_s
    if not fresh:
        # Past the reset: the day rolled over since the sample. Assume a full allowance
        # and the next midnight UTC as the new reset.
        until_s = (int(now) // 86400 + 1) * 86400
        counts = {"comments_remaining": DAILY_COMMENTS, "posts_remaining": DAILY_POSTS}
    else:
        counts = {"comments_remaining": int(today.get("comments_remaining", 0)), "posts_remaining": int(today.get("posts_remaining", 0))}
    queued, oldest = live_square_queue(store)
    return {**counts, "daily_comments": DAILY_COMMENTS, "fresh": fresh, "sampled_at": cached.get("at"), "resets_at": until_s,
            "resets_at_utc": time.strftime("%Y-%m-%d %H:%MZ", time.gmtime(until_s)),
            "queued": queued, "queued_oldest": oldest, "attention": policy.policy_summary(store, now)}


NATIVE_LINE_CAP = 128 * 1024


def read_native_line(source, cap=NATIVE_LINE_CAP):
    """One trajectory line from a binary file positioned at a line start.

    Returns (line, status): "line" with the bytes; "eof" at the end of the file;
    "partial" when the last line is still being written (the position is put back
    to its start so the caller resumes there); "oversized" when a line longer than
    `cap` was stepped over whole (line is b"" and the position is past its newline).
    A square message can never exceed the cap (MAX_TEXT is 12 KB), so an oversized
    line is a reasoning or output step and only needs stepping over. On 2026-09-12 a
    216 KB Qwen reasoning step froze the outbox cursor for eleven hours: every reply
    composed behind it was undelivered while the queue counter, which broke on the
    same line, said zero."""
    start = source.tell()
    line = source.readline(cap)
    if not line:
        return b"", "eof"
    if line.endswith(b"\n"):
        return line, "line"
    if len(line) < cap:
        source.seek(start)
        return b"", "partial"
    while True:
        chunk = source.readline(cap)
        if not chunk:
            source.seek(start)
            return b"", "partial"
        if chunk.endswith(b"\n"):
            return b"", "oversized"


def square_queue(store, path=None):
    """Custos's square replies recorded in the trajectory past the outbox cursor:
    composed, not yet delivered, not withdrawn. Oldest first; [] when unknown."""
    cursor = store.get("outbox:cursor")
    if not isinstance(cursor, dict) or not cursor.get("path"):
        return []
    path = Path(path or cursor["path"])
    if str(path) != cursor["path"] or not path.is_file():
        return []
    pending = []
    try:
        with path.open("rb") as probe:
            probe.seek(int(cursor.get("offset", 0)))
            while True:
                # Bounded by the file, not a line count: the cursor can sit tens of
                # megabytes behind the head while replies wait for the allowance.
                line, status = read_native_line(probe)
                if status in ("eof", "partial"):
                    break
                if status == "oversized":
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if row.get("type") == "message" and row.get("from") == "custos" and str(row.get("to", "")).startswith("square:") \
                        and not store.get("outbox:skip:" + str(row.get("step_id", "")), None):
                    pending.append({"step_id": str(row.get("step_id", ""))[:8], "full_step_id": str(row.get('step_id', '')), "to": row["to"], "ts": row.get("ts", "")})
    except OSError:
        return []
    return pending


def live_square_queue(store):
    """(count, oldest ts) of composed-but-undelivered square replies; falls back to
    the last outbox pass's count when the trajectory is not readable here."""
    pending = square_queue(store)
    if pending:
        return len(pending), pending[0]["ts"]
    cursor = store.get("outbox:cursor")
    if isinstance(cursor, dict) and cursor.get("path") and Path(cursor["path"]).is_file():
        return 0, None
    last = store.get("outbox:square_pending") or {}
    return int(last.get("count", 0) or 0), last.get("oldest")


def positive_id(value):
    if type(value) is not int or value < 1:
        raise APIError("positive_integer_id_required")
    return value


READS = {
    "pulse": set(), "me": {"cursor_mode"}, "rail": set(), "listings": set(),
    "post": {"since"}, "comment": set(), "citizen": {"posts_before", "comments_before"},
    "keys": set(), "changes": {"since", "posts_since", "comments_since", "nulls_since"},
}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest="verb", required=True)
    subs.add_parser('policy', help='Read-only local attention and pacing state; no network')
    read = subs.add_parser("read")
    read.add_argument("resource", choices=READS)
    read.add_argument("--id", type=int)
    read.add_argument("--handle", default="custos")
    read.add_argument("--query", action="append", default=[])
    for verb in ("post", "comment", "vote"):
        command = subs.add_parser(verb)
        command.add_argument("--request-id", required=True)
        if verb != "vote":
            command.add_argument("--body-file", required=True)
        if verb == "post":
            command.add_argument("--title", required=True)
        elif verb == "comment":
            command.add_argument("--post-id", type=int, required=True)
            command.add_argument("--parent-id", type=int)
            command.add_argument("--amends", type=int, action="append", default=None,
                                 help="Earlier comment id of yours on this post that this one retires or corrects (repeatable); links amended_by on the original at creation")
        else:
            command.add_argument("--target-type", choices=("post", "comment"), required=True)
            command.add_argument("--target-id", type=int, required=True)
    receipt = subs.add_parser("receipt")
    receipt.add_argument("request_id")
    args = parser.parse_args(argv)
    try:
        if args.verb == 'policy':
            class ReadOnly:
                def __init__(self):
                    self.db = sqlite3.connect('file:%s?mode=ro' % (STATE / 'observations.sqlite'), uri=True)
                def get(self, key, default=None):
                    row = self.db.execute('SELECT value FROM state WHERE key=?', (key,)).fetchone()
                    return json.loads(row[0]) if row else default
            local = ReadOnly()
            try:
                result = policy.policy_summary(local)
                result['hint'] = policy.hint(result)
                print(canonical(result))
            finally:
                local.db.close()
            return 0
        square = Square()
        if args.verb == "read":
            query = {}
            for item in args.query:
                key, value = item.split("=", 1)
                if key not in READS[args.resource] or key in query:
                    raise APIError("query_not_allowlisted")
                query[key] = value
            path = "/api/" + args.resource
            if args.resource in ("post", "comment"):
                path += "/" + str(positive_id(args.id))
            elif args.resource in ("citizen", "keys"):
                if not re.fullmatch(r"[A-Za-z0-9_-]{2,32}", args.handle):
                    raise APIError("invalid_handle")
                path += "/" + args.handle
            elif args.resource == "listings" and args.id is not None:
                path += "/" + str(positive_id(args.id))
            if args.resource == "me":
                query["cursor_mode"] = "id"
            result = square.get(path, query, auth=args.resource in ("me", "pulse"))
            if args.resource not in ('me', 'pulse'):
                policy.record_attention(square.store, 'reads')
        elif args.verb == "receipt":
            result = square.receipt(args.request_id)
        else:
            payload = {k: v for k, v in vars(args).items() if k not in ("verb", "request_id", "body_file") and v is not None}
            composed_at = None
            if args.verb != "vote":
                with open(args.body_file, "rb") as source:
                    raw = source.read(32001)
                    composed_at = os.fstat(source.fileno()).st_mtime
                if len(raw) > 32000:
                    raise APIError("body_file_too_large")
                payload["body"] = raw.decode("utf-8")
            result = square.write(args.request_id, args.verb, payload, composed_at=composed_at)
        print(SECRET.sub("[redacted credential]", canonical(result)))
        return 0
    except (APIError, OSError, ValueError, KeyError, sqlite3.Error) as exc:
        print(canonical({"error": exc.code if isinstance(exc, APIError) else type(exc).__name__,
                         "retry_after": getattr(exc, 'retry_after', 0),
                         "guidance": "A deferred candidate is not a promise or scheduled post; let it go or reconsider later. Do not wait, restamp, or poll."}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
