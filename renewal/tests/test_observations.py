import gzip
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from custos_observe import Observer, classify_opportunity, housekeep, import_continuity, record_result
from custos_square import APIError, Square, Store, public_request


class NativeFixture:
    def __init__(self):
        self.events = []
        self.goals = {}
        self.messages = {}
        self.fail_capture = False

    def capture(self, payload):
        if self.fail_capture:
            raise APIError("native_capture_failed")
        key = payload["request_id"]
        self.goals.setdefault(key, "goal-" + str(len(self.goals)))
        self.events.append(("capture", key))
        return {"goal_id": self.goals[key], "request_id": key, "created": True}

    def append(self, identity, envelope):
        self.messages.setdefault(identity, envelope)
        self.events.append(("append", identity))
        return identity


def item(number, post=10, author="neighbour"):
    return {"id": number, "comment_id": number, "post_id": post, "author": author, "body": "Please check the source and answer", "created_at": 1000}


def page(items, comments=12, mentions=90, more=False):
    return {"handle": "custos", "cursor_mode": "id", "ack_cursor": {"version": 1, "timestamp": 123456, "comments": comments, "mentions": mentions}, "since_last_visit": {"contract": "1f916.inbox.since_last_visit.v5", "replies": items, "comments_on_your_posts": [], "mentions_of_you": [], "in_threads_you_joined": [], "truncated": {"replies": more}}}


class InboxFixture:
    def __init__(self, pages, events):
        self.pages = pages
        self.events = events
        self.acks = []
        self.fail_ack = False

    def get(self, path, query=None, auth=False):
        if path == "/api/pulse":
            return {"you": {"handle": "custos", "has_new_for_you": True}}
        if query != {"cursor_mode": "id"}:
            raise AssertionError("ID mode must be explicit each read")
        return self.pages[min(len(self.acks), len(self.pages) - 1)]

    def request(self, path, query=None, **kwargs):
        if path != "/api/me/ack":
            raise AssertionError(path)
        self.events.append(("ack", kwargs["body"]["up_to"]))
        if self.fail_ack:
            raise APIError("transport_uncertain")
        self.acks.append(kwargs["body"]["up_to"])
        return {}, None


class HousekeepingTests(unittest.TestCase):
    def test_only_stale_scratch_is_removed_and_big_logs_rotate_by_copy_truncate(self):
        import os
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); now = 10_000_000
            tmp, jobs, logs = root / "tmp", root / "jobs", root / "logs"
            for d in (tmp, jobs, logs):
                d.mkdir()
            def make(path, age, content=b"x" * 10, git=False):
                if path.suffix == ".txt" or path.name.endswith(".log"):
                    path.write_bytes(content)
                else:
                    path.mkdir()
                    (path / "file").write_bytes(content)
                    if git:
                        (path / ".git").mkdir()
                for p in [path] + list(path.rglob("*")) if path.is_dir() else [path]:
                    os.utime(p, (now - age, now - age))
            make(tmp / "pr172", 3 * 86400, git=True)            # stale clone: removed
            make(tmp / "pr262", 3600, git=True)                 # young clone: kept
            make(tmp / "notes", 30 * 86400)                     # not a clone: kept
            make(tmp / "subrun-old.txt", 8 * 86400)             # old report: removed
            make(tmp / "subrun-new.txt", 60)                    # young report: kept
            make(jobs / "20260901T000000Z-aaaa", 8 * 86400)     # old sandbox: removed
            make(jobs / "20260917T000000Z-bbbb", 3600)          # young sandbox: kept
            make(logs / "monolith.log", 0, content=b"m" * 200)
            make(logs / "small.log", 0, content=b"s" * 10)
            make(tmp / "pr300-wt", 3600, git=True)              # young, but its PR is settled: removed
            (tmp / "pr301-wt").mkdir(); (tmp / "pr301-wt" / ".git").write_text("gitdir: elsewhere")  # a worktree: removed
            (logs / "social.log.1").write_bytes(b"s" * 50)      # leftover plain rotation: compressed
            report = housekeep(now, tmp=tmp, jobs=jobs, logs=logs, log_bytes=100, settled={"300", 301}, clones=root / "none")
            import gzip
            self.assertTrue((tmp / "pr300-wt").exists()); self.assertTrue((tmp / "pr301-wt").exists())
            self.assertFalse((logs / "social.log.1").exists())
            self.assertEqual(gzip.open(logs / "social.log.1.gz").read(), b"s" * 50)
            self.assertEqual([Path(p).name for p in report["compressed"]], ["social.log.1"])
            self.assertTrue((tmp / "pr172").exists()); self.assertTrue((tmp / "pr262").exists())
            self.assertTrue((tmp / "notes").exists())
            self.assertFalse((tmp / "subrun-old.txt").exists()); self.assertTrue((tmp / "subrun-new.txt").exists())
            self.assertFalse((jobs / "20260901T000000Z-aaaa").exists()); self.assertTrue((jobs / "20260917T000000Z-bbbb").exists())
            self.assertEqual((logs / "monolith.log").stat().st_size, 0)
            self.assertEqual(gzip.open(logs / "monolith.log.1.gz").read(), b"m" * 200)
            self.assertFalse((logs / "monolith.log.1").exists())
            self.assertEqual((logs / "small.log").stat().st_size, 10)
            self.assertEqual(sorted(Path(p).name for p in report["removed"]), ["20260901T000000Z-aaaa", "subrun-old.txt"])
            self.assertEqual([Path(p).name for p in report["rotated"]], ["monolith.log"])
            # Missing roots are not an error.
            self.assertEqual(housekeep(now, tmp=root / "none", jobs=root / "none", logs=None)["removed"], [])


class SettledPullRequestTests(unittest.TestCase):
    def test_settled_prs_come_from_the_github_prs_snapshots(self):
        with tempfile.TemporaryDirectory() as temp:
            store = Store(temp)
            store.put("github-prs:inventory", {"1f916-ai/1f916#5": {"repo": "1f916-ai/1f916", "number": 5},
                                               "1f916-ai/1f916#6": {"repo": "1f916-ai/1f916", "number": 6},
                                               "laude-institute/headlong#7": {"repo": "laude-institute/headlong", "number": 7}})
            store.put("github-prs:pr:1f916-ai/1f916#5", {"snapshot": {"pr": {"state": "closed"}}})
            store.put("github-prs:pr:1f916-ai/1f916#6", {"snapshot": {"pr": {"state": "open"}}})
            store.put("github-prs:pr:laude-institute/headlong#7", {"snapshot": {"pr": {"state": "merged"}}})
            observer = Observer({}, store, None, NativeFixture(), now=1.0)
            self.assertEqual(observer.settled_prs(), {"5", "7"})
            store.db.close()


class ObservationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = Store(self.temp.name)
        self.addCleanup(self.store.db.close)
        self.native = NativeFixture()

    def observer(self, square, **config):
        return Observer(config, self.store, square, self.native, now=2000)

    def test_capture_failure_prevents_page_ack_and_retry_deduplicates_goals(self):
        response = page([item(11), item(12)])
        api = InboxFixture([response], self.native.events)
        self.native.fail_capture = True
        with self.assertRaises(APIError):
            self.observer(api).inbox()
        self.assertEqual(api.acks, [])
        self.assertIsNone(self.store.get("inbox:cursor"))
        self.native.fail_capture = False
        api.fail_ack = True
        with self.assertRaises(APIError):
            self.observer(api).inbox()
        self.assertEqual(len(self.native.goals), 2)
        api.fail_ack = False
        self.observer(api).inbox()
        self.assertEqual(len(self.native.goals), 2)
        self.assertEqual(api.acks, [response["ack_cursor"]])
        self.assertEqual([x[0] for x in self.native.events[:5]], ["capture", "append", "capture", "append", "ack"])

    def test_partial_page_signal_budget_does_not_ack_undelivered_item(self):
        api = InboxFixture([page([item(11), item(12)])], self.native.events)
        self.observer(api, max_signals_per_run=1).inbox()
        self.assertEqual(api.acks, [])
        self.assertEqual(set(self.native.goals), {"square:comment:11"})
        self.observer(api, max_signals_per_run=1).inbox()
        self.assertEqual(len(api.acks), 1)
        self.assertEqual(set(self.native.goals), {"square:comment:11", "square:comment:12"})

    def test_square_capacity_is_reserved_before_native_capture_or_composition(self):
        response = page([item(11)])
        response["today"] = {"comments_remaining": 1, "posts_remaining": 1,
                             "interval": {"until": 9_999_999_000}}
        self.store.put("outbox:square_pending", {"count": 1, "oldest": "2026-09-14T00:00:00Z"})
        api = InboxFixture([response], self.native.events)
        self.observer(api).inbox()
        self.assertEqual(self.native.goals, {})
        self.assertEqual(self.native.messages, {})
        row = self.store.db.execute("SELECT disposition,payload FROM seen WHERE id='square:comment:11'").fetchone()
        self.assertEqual(row["disposition"], "capacity_skipped")
        self.assertIn("no unreserved square reply slot", row["payload"])
        self.assertEqual(api.acks, [response["ack_cursor"]])

    def test_id_pagination_preserves_exact_mention_watermark_and_overlap(self):
        first = page([item(11)], comments=11, mentions=999, more=True)
        first["since_last_visit"]["mentions_of_you"] = [dict(item(11), mention_id=999)]
        second = page([item(12)], comments=12, mentions=1002)
        api = InboxFixture([first, second], self.native.events)
        self.observer(api, inbox_pages_per_run=2).inbox()
        self.assertEqual(api.acks, [first["ack_cursor"], second["ack_cursor"]])
        self.assertEqual(len(self.native.goals), 2)
        self.assertTrue(self.store.seen("inbox:mentions_of_you:999"))

    def test_post_mention_routes_to_post_not_notification_id(self):
        response = page([])
        response["since_last_visit"]["mentions_of_you"] = [{"id": None, "comment_id": None, "mention_id": 777, "post_id": 44, "author": "neighbour", "body": "@custos please inspect"}]
        api = InboxFixture([response], self.native.events)
        self.observer(api).inbox()
        message = self.native.messages["square:post:44"]
        self.assertEqual(message["from"], "square:neighbour:44:0")
        self.assertEqual(message["source_url"], "https://1f916.ai/api/post/44")
        self.assertEqual(message["authority"], "agent")

    def test_contract_pin_accepts_v5_shape_and_rejects_unwritten_versions(self):
        response = page([item(11)])
        response["since_last_visit"]["truncated"] = False
        api = InboxFixture([response], self.native.events)
        self.observer(api).inbox()
        self.assertEqual(len(self.native.goals), 1)
        self.assertEqual(api.acks, [response["ack_cursor"]])
        old = page([item(12)])
        old["since_last_visit"]["contract"] = "1f916.inbox.since_last_visit.v3"
        api2 = InboxFixture([old], self.native.events)
        with self.assertRaises(APIError) as ctx:
            self.observer(api2).inbox()
        self.assertEqual(ctx.exception.code, "inbox_contract_changed")
        self.assertEqual(api2.acks, [])

    def test_continuity_preserves_fulfilled_and_captures_remaining_before_ack(self):
        snapshot = {"items": [{"request_id": "square:comment:" + str(n), "source_url": "https://1f916.ai/api/comment/" + str(n), "sender": "square:neighbour:10:" + str(n), "content": "original ask", "previous_replies": [99] if n == 11 else []} for n in (11, 12)], "ack_cursor": page([])["ack_cursor"]}
        self.assertFalse(import_continuity(self.store, snapshot)["acknowledged"])
        api = InboxFixture([page([item(11), item(12)])], self.native.events)
        self.observer(api).inbox()
        self.assertEqual(set(self.native.goals), {"square:comment:12"})
        self.assertEqual(len(api.acks), 1)

    def test_source_failure_and_recovery_alert_only_on_transition(self):
        observer = self.observer(None)
        def fail():
            raise APIError("http_503")
        observer.source("research", 10, fail)
        observer.now += 1000
        observer.source("research", 10, fail)
        self.assertEqual(len(self.native.messages), 1)
        self.assertEqual(self.store.get("source:research")["error"], "http_503")
        observer.now += 1000
        observer.source("research", 10, lambda: None)
        observer.now += 1000
        observer.source("research", 10, lambda: None)
        self.assertEqual(len(self.native.messages), 2)
        self.assertNotIn("error", self.store.get("source:research"))

    def test_changes_continuation_and_same_query_etag(self):
        calls = []
        responses = [{"posts": [], "comments": [], "has_more": True, "has_more_streams": ["posts", "comments"], "continuation_covers": ["posts", "comments"], "next_posts_since": "snapi:50:20", "next_comments_since": "id:60", "next_nulls_since": "done"}, {"posts": [], "comments": [], "has_more": False, "has_more_streams": ["posts", "comments"], "continuation_covers": ["posts", "comments"], "next_posts_since": "snapi:50:20", "next_comments_since": "id:60", "next_nulls_since": "done"}]
        class Changes:
            def request(self, path, query, etag=None):
                calls.append((dict(query), etag))
                if len(calls) <= 2:
                    return responses[len(calls) - 1], '"tag"'
                return None, etag
        observer = self.observer(Changes(), square_interests={"terms": ["memory"]}, changes_pages_per_run=2)
        observer.changes()
        observer.changes()
        self.assertEqual(calls[0][0]["posts_since"], "init")
        self.assertEqual(calls[1][0]["posts_since"], "snapi:50:20")
        self.assertIsNone(calls[1][1])
        self.assertEqual(calls[2][1], '"tag"')

    def test_feed_first_read_is_baseline_then_only_new_matching_item(self):
        feed = {"name": "selected", "url": "https://research.invalid/rss", "terms": ["memory"]}
        first = b'<rss><channel><item><guid>old</guid><title>Memory paper</title><link>https://paper.invalid/old</link></item></channel></rss>'
        second = b'<rss><channel><item><guid>new</guid><title>Memory result</title><link>https://paper.invalid/new</link></item><item><guid>old</guid><title>Memory paper</title><link>https://paper.invalid/old</link></item></channel></rss>'
        observer = self.observer(None)
        with patch("custos_observe.public_request", side_effect=[(first, "a", 200), (second, "b", 200), (second, "b", 200)]):
            observer.feed(feed)
            self.assertEqual(self.native.messages, {})
            observer.feed(feed)
            observer.feed(feed)
        self.assertEqual(len(self.native.messages), 1)
        self.assertIn("Memory result", next(iter(self.native.messages.values()))["content"])

    def test_feed_pending_survives_budget_before_next_remote_snapshot(self):
        feed = {"name": "selected", "url": "https://research.invalid/rss"}
        observer = self.observer(None, max_signals_per_run=1)
        empty = b"<rss><channel/></rss>"
        fresh = b"<rss><channel><item><guid>one</guid><title>First</title></item><item><guid>two</guid><title>Second</title></item></channel></rss>"
        with patch("custos_observe.public_request", side_effect=[(empty, "a", 200), (fresh, "b", 200)]) as request:
            observer.feed(feed)
            observer.feed(feed)
            self.assertEqual(len(self.native.messages), 1)
            self.observer(None, max_signals_per_run=1).feed(feed)
            self.assertEqual(len(self.native.messages), 2)
            self.assertEqual(request.call_count, 2)

    def test_feed_transient_parse_error_retries_once_and_recovers(self):
        # A truncated body from the upstream CDN (observed on news.un.org) must
        # force one fresh full fetch rather than failing the whole source.
        feed = {"name": "un", "url": "https://news.un.invalid/rss"}
        malformed = b'<rss><channel><item><guid>one</guid><title>Trunc'
        good = b'<rss><channel><item><guid>one</guid><title>One</title></item></channel></rss>'
        observer = self.observer(None)
        with patch("custos_observe.public_request", side_effect=[(malformed, "a", 200), (good, "b", 200)]) as request, \
                patch("custos_observe.time.sleep") as sleep:
            observer.feed(feed)
        self.assertEqual(request.call_count, 2)
        self.assertEqual(sleep.call_count, 1)
        # The recovered read is the initial baseline, so no message yet.
        self.assertEqual(self.native.messages, {})

    def test_feed_persistent_parse_error_retries_once_then_fails(self):
        # A second malformed body must still raise (exactly one retry, not a loop).
        feed = {"name": "un", "url": "https://news.un.invalid/rss"}
        malformed = b'<rss><channel><item><guid>one</guid><title>Trunc'
        observer = self.observer(None)
        with patch("custos_observe.public_request", side_effect=[(malformed, "a", 200), (malformed, "b", 200)]) as request, \
                patch("custos_observe.time.sleep") as sleep:
            with self.assertRaises(ET.ParseError):
                observer.feed(feed)
        self.assertEqual(request.call_count, 2)
        self.assertEqual(sleep.call_count, 1)

    def test_opportunity_excludes_exhausted_unfunded_and_labels_snapshot(self):
        detail = {"listing_id": 20, "title": "Useful source fix", "amount_atomic": "5000000", "chain_id": 8453, "token": "0x" + "a" * 40, "expiry": 5000, "economics": {"available_award_capacity": 0}, "condition": "Check a real fix", "funding_mode": "promise"}
        self.assertIsNone(classify_opportunity(detail, 2000))
        detail["economics"]["available_award_capacity"] = 1
        self.assertIsNone(classify_opportunity(detail, 2000))
        detail.update(funder_address="0x" + "b" * 40, funds_seen_atomic="5000000")
        self.assertIn("NOT locked", classify_opportunity(detail, 2000)["funding"])
        detail.update(funding_mode="funded", funding_status={"funded": False})
        self.assertIsNone(classify_opportunity(detail, 2000))

    def test_uncertain_post_is_reconciled_without_second_network_write(self):
        class Posting(Square):
            def __init__(self, store):
                super().__init__(store)
                self.posts = 0
                self.published = []
            def validate(self, verb, payload):
                pass
            def get(self, path, query=None, auth=False):
                if path == "/api/me":
                    return {"handle": "custos", "today": {"comments_remaining": 20}}
                return {"comments": self.published}
            def request(self, path, query=None, **kwargs):
                self.posts += 1
                self.published.append(dict(kwargs["body"], id=991, author="custos", created_at=2000000))
                raise APIError("transport_uncertain")
        api = Posting(self.store)
        payload = {"post_id": 44, "parent_id": 18, "body": "The verified result"}
        with patch("custos_square.time.time", return_value=2000):
            with self.assertRaises(APIError):
                api.write("stable", "comment", payload)
            receipt = api.write("stable", "comment", payload)
        self.assertEqual(api.posts, 1)
        self.assertEqual(receipt["readback"], "https://1f916.ai/api/comment/991")
        self.assertEqual(api.write("stable", "comment", payload), receipt)
        self.assertEqual(api.posts, 1)

    def test_success_receipt_survives_public_read_outage_with_exact_target(self):
        api = Square(self.store)
        payload = {"post_id": 44, "body": "result"}
        def unavailable(path, query=None, auth=False):
            if path == "/api/me":
                return {"handle": "custos", "today": {"comments_remaining": 20}}
            raise APIError("http_503")
        with patch.object(api, "validate"), patch.object(api, "get", side_effect=unavailable), patch.object(api, "request", return_value=({"comment_id": 992}, None)) as request, patch("custos_square.time.time", return_value=2000):
            with self.assertRaises(APIError):
                api.write("known-target", "comment", payload)
            self.assertEqual(request.call_count, 1)
        target = {"comment": dict(payload, id=992, author="custos", created_at=2000000)}
        with patch.object(api, "get", return_value=target) as readback, patch.object(api, "request") as request:
            receipt = api.write("known-target", "comment", payload)
            readback.assert_called_once_with("/api/comment/992")
            request.assert_not_called()
        self.assertEqual(receipt["readback"], "https://1f916.ai/api/comment/992")

    def test_absent_uncertain_readback_never_authorizes_retry(self):
        with self.store.db:
            self.store.db.execute("INSERT INTO outbound VALUES (?,?,?,?,?,?)", ("lost", "comment", json.dumps({"post_id": 44, "body": "result"}, sort_keys=True, separators=(",", ":")), "uncertain", None, 2000))
        api = Square(self.store)
        with patch.object(api, "get", return_value={"comments": []}), patch.object(api, "request") as request:
            with self.assertRaisesRegex(APIError, "manual_review_no_retry"):
                api.write("lost", "comment", {"post_id": 44, "body": "result"})
            request.assert_not_called()

    def test_github_baseline_etag_and_changed_result_are_not_repeated(self):
        observer = self.observer(None)
        fields = ("id", "name", "status", "conclusion")
        pending = [{"id": 1, "name": "unit tests", "status": "in_progress", "conclusion": None}]
        completed = [dict(pending[0], status="completed", conclusion="failure")]
        with patch("custos_observe.public_request", side_effect=[(json.dumps(pending).encode(), "a", 200), (json.dumps(completed).encode(), "b", 200), (b"", "b", 304)]) as request:
            observer.github_snapshot("owner/public", "checks", "/checks", None, fields, True)
            self.assertEqual(self.native.messages, {})
            observer.github_snapshot("owner/public", "checks", "/checks", None, fields, False)
            observer.github_snapshot("owner/public", "checks", "/checks", None, fields, False)
            self.assertEqual(request.call_args.args[1], "b")
        self.assertEqual(len(self.native.messages), 1)
        self.assertIn('"conclusion":"failure"', next(iter(self.native.messages.values()))["content"])

    def test_github_review_page_continuation_preserves_history_baseline(self):
        observer = self.observer(None)
        calls = []
        def snapshot(repo, surface, path, collection, fields, baseline):
            if surface == "pull requests":
                return [{"number": 7}]
            if surface.endswith("reviews"):
                calls.append((path, baseline))
                return [{"id": n} for n in range(30)] if "page=1" in path else [{"id": 31}]
            return []
        with patch.object(observer, "github_snapshot", side_effect=snapshot):
            observer.github({"repo": "owner/public"})
            observer.github({"repo": "owner/public"})
        self.assertEqual(calls, [("/pulls/7/reviews?per_page=30&page=1", True), ("/pulls/7/reviews?per_page=30&page=2", True)])

    def test_owned_outcome_callback_requires_evidence_and_deduplicates(self):
        proof = Path(self.temp.name) / "test-output.txt"
        proof.write_text("Command exited 1; expected regression reproduced.")
        result = {"request_id": "test:regression-1", "project": "custos", "kind": "test", "status": "failed", "summary": "Regression reproduced, not fixed.", "evidence": [{"path": str(proof), "sha256": hashlib.sha256(proof.read_bytes()).hexdigest()}]}
        self.assertTrue(record_result(self.store, result)["created"])
        self.assertFalse(record_result(self.store, result)["created"])
        with self.assertRaisesRegex(APIError, "id_conflict"):
            record_result(self.store, dict(result, status="succeeded"))
        observer = self.observer(None)
        observer.local_results()
        observer.local_results()
        self.assertEqual(len(self.native.messages), 1)
        self.assertIn('"status":"failed"', next(iter(self.native.messages.values()))["content"])
        proof.write_text("Different evidence")
        with self.assertRaisesRegex(APIError, "digest_mismatch"):
            record_result(self.store, dict(result, request_id="test:tampered"))

    def test_local_git_is_quiet_at_baseline_and_reports_no_invented_ci(self):
        observer = self.observer(None)
        project = {"name": "custos", "path": self.temp.name}
        values = ["a" * 40, "aaaaaaa Original change", "", "b" * 40, "bbbbbbb Next change", " source.py | 2 +-", "b" * 40, "bbbbbbb Next change", " source.py | 2 +-"]
        with patch("custos_observe.subprocess.run", side_effect=[SimpleNamespace(returncode=0, stdout=value) for value in values]):
            observer.local_git(project)
            self.assertEqual(self.native.messages, {})
            observer.local_git(project)
            observer.local_git(project)
        self.assertEqual(len(self.native.messages), 1)
        self.assertIn("no claim of test, delivery, review or CI success", next(iter(self.native.messages.values()))["content"])


if __name__ == "__main__":
    unittest.main()


class SquareOutboxTests(unittest.TestCase):
    """Replies composed past the daily comment allowance: they must wait for the
    reset (not an exponential backoff), the mind must hear about each one, and a
    stale one can be withdrawn without losing the ones behind it."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = Store(self.temp.name)
        self.addCleanup(self.store.db.close)
        self.traj = Path(self.temp.name) / "traj.jsonl"
        self.traj.write_text("")
        self.native = NativeFixture()
        self.native.path = self.traj
        self.now = 1788960000.0  # 2026-09-09 13:20Z
        self.reset_ms = 1788998400000  # 2026-09-10 00:00Z

    def compose(self, step, handle="egress", post=3100, parent=50000):
        row = {"type": "message", "from": "custos", "to": "square:%s:%d:%d" % (handle, post, parent),
               "content": "reply " + step, "step_id": step, "ts": "2026-09-09T13:0%s:00.000Z" % step[-1]}
        with self.traj.open("a") as out:
            out.write(json.dumps(row) + "\n")

    def square(self, remaining):
        store = self.store
        class Fake(Square):
            def __init__(self):
                super().__init__(store)
                self.remaining = remaining
                self.posted = []
            def validate(self, verb, payload):
                pass
            def get(self, path, query=None, auth=False):
                if path == "/api/me":
                    return {"handle": "custos", "today": {"comments_remaining": self.remaining, "posts_remaining": 1,
                                                          "interval": {"until": 1788998400000, "utc_date": "2026-09-09"}}}
                return {"comment": {"author": "egress"}, "post": {"author": "egress"}}
            def request(self, path, query=None, **kwargs):
                self.remaining -= 1
                self.posted.append(kwargs["body"]["body"])
                return {"id": 700 + len(self.posted)}, None
            def receipt(self, identity):
                return {"request_id": identity, "status": "delivered"}
        return Fake()

    def observer(self, api):
        return Observer({}, self.store, api, self.native, now=self.now)

    def test_allowance_exhausted_waits_until_reset_and_reports_each_queued_reply(self):
        api = self.square(remaining=1)
        self.store.put('square:directed:3100:50000', {'at': self.now, 'request_id': 'verified-incoming'})
        for step in ("aaaaaaa1", "aaaaaaa2", "aaaaaaa3"):
            self.compose(step)
        observer = self.observer(api)
        with patch("custos_square.time.time", return_value=self.now), patch("custos_observe.time.time", return_value=self.now):
            observer.source("square-outbox", 60, observer.outbox)
        # One went out, the second hit the allowance, the third never reached the API.
        self.assertEqual(api.posted, ["reply aaaaaaa1"])
        self.assertIn("delivery:aaaaaaa1", self.native.messages)
        waiting = self.native.messages["allowance-wait:aaaaaaa2"]["content"]
        self.assertIn("2 replies queued", waiting)
        self.assertIn("2026-09-10T00:00Z", waiting)
        self.assertIn("custos-observe withdraw aaaaaaa2", waiting)
        self.assertNotIn("allowance-wait:aaaaaaa3", self.native.messages)
        # The source retries at the reset (+30 s), not after an exponential backoff.
        state = self.store.get("source:square-outbox")
        self.assertEqual(state["deferred"], "platform_allowance_exhausted")
        self.assertAlmostEqual(state["next"], self.reset_ms / 1000 + 30, delta=1)
        # Queue depth and the cached allowance are visible to other processes.
        from custos_square import allowance_summary, square_queue
        self.assertEqual([p["step_id"] for p in square_queue(self.store)], ["aaaaaaa2", "aaaaaaa3"])
        summary = allowance_summary(self.store, now=self.now)
        self.assertEqual((summary["comments_remaining"], summary["queued"], summary["fresh"]), (0, 2, True))
        self.assertEqual(summary["resets_at_utc"], "2026-09-10 00:00Z")
        # After the reset the day rolls over: a full allowance is assumed until the next sample.
        rolled = allowance_summary(self.store, now=self.reset_ms / 1000 + 5)
        self.assertEqual((rolled["comments_remaining"], rolled["fresh"]), (20, False))

    def test_repeat_pass_before_reset_does_not_renotify_and_delivers_in_order_after(self):
        api = self.square(remaining=0)
        self.compose("bbbbbbb1")
        self.compose("bbbbbbb2")
        observer = self.observer(api)
        with patch("custos_square.time.time", return_value=self.now), patch("custos_observe.time.time", return_value=self.now):
            observer.source("square-outbox", 60, observer.outbox)
            observer.now += 600
            observer.source("square-outbox", 60, observer.outbox)  # still backing off: nothing happens
        self.assertEqual([k for k in self.native.messages if k.startswith("allowance-wait:")], ["allowance-wait:bbbbbbb1"])
        api.remaining = 20
        observer.now = self.reset_ms / 1000 + 31
        with patch("custos_square.time.time", return_value=observer.now):
            observer.source("square-outbox", 60, observer.outbox)
        self.assertEqual(api.posted, ["reply bbbbbbb1", "reply bbbbbbb2"])
        self.assertNotIn("recovery:square-outbox:1", self.native.messages)
        self.assertEqual(self.store.get("outbox:square_pending")["count"], 0)

    def test_withdrawn_reply_is_skipped_and_the_rest_still_deliver(self):
        api = self.square(remaining=20)
        self.compose("ccccccc1")
        self.compose("ccccccc2")
        self.compose("ccccccc3")
        from custos_observe import main
        import io, contextlib
        with patch("custos_observe.Store", return_value=self.store), contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main(["withdraw", "ccccccc2"]), 0)
        self.assertIn("ccccccc2", out.getvalue())
        observer = self.observer(api)
        with patch("custos_square.time.time", return_value=self.now):
            observer.source("square-outbox", 60, observer.outbox)
        self.assertEqual(api.posted, ["reply ccccccc1", "reply ccccccc3"])
        self.assertIn("withdrawn:ccccccc2", self.native.messages)
        self.assertNotIn("delivery:ccccccc2", self.native.messages)
        from custos_square import square_queue
        self.assertEqual(square_queue(self.store), [])


    def test_amends_validation_pins_wire_shape(self):
        class Amends(Square):
            def __init__(self, store):
                super().__init__(store)
            def key(self):
                return "1f916_sk_" + "a" * 20
            def get(self, path, query=None, auth=False):
                if path.startswith("/api/post/"):
                    return {"post": {"mod_state": None}}
                if path.startswith("/api/comment/"):
                    return {"comment": {"post_id": 44, "mod_state": None}}
                raise AssertionError(path)
        api = Amends(self.store)
        # scalar and list of positive ints are valid correction links
        api.validate("comment", {"post_id": 44, "body": "The verified result", "amends": 18})
        api.validate("comment", {"post_id": 44, "body": "The verified result", "amends": [18, 20]})
        # an empty list is not a correction link
        with self.assertRaisesRegex(APIError, "amends_must_be_comment_ids"):
            api.validate("comment", {"post_id": 44, "body": "The verified result", "amends": []})
        # a non-positive or non-int id fails before a write is spent
        with self.assertRaisesRegex(APIError, "positive_integer_id_required"):
            api.validate("comment", {"post_id": 44, "body": "The verified result", "amends": [18, 0]})
        with self.assertRaisesRegex(APIError, "positive_integer_id_required"):
            api.validate("comment", {"post_id": 44, "body": "The verified result", "amends": "18"})


class SelfMetricsTests(unittest.TestCase):
    def test_metrics_count_wakes_waste_deliveries_and_responder_outcomes(self):
        from custos_observe import self_metrics, metrics_text
        now = 1788960000.0
        def ts(ago):
            import time as _t
            return _t.strftime("%Y-%m-%dT%H:%M:%S.000Z", _t.gmtime(now - ago))
        rows = [
            {"type": "shellm-run", "step_id": "r1", "launched_by": "monolith", "ts": ts(3600)},
            {"type": "reasoning", "run_id": "r1", "thought": "The output got truncated, re-reading", "cmd": "traj show x --full", "llm_s": 30, "ts": ts(3590)},
            {"type": "reasoning", "run_id": "r1", "thought": "now the tests", "cmd": "npm test", "llm_s": 30, "ts": ts(3580)},
            {"type": "observation", "run_id": "r1", "source": "executive", "content": "tests pass", "ts": ts(3570)},
            {"type": "run-end", "run_id": "r1", "rc": 0, "ts": ts(3560)},
            {"type": "shellm-run", "step_id": "r2", "launched_by": "monolith", "ts": ts(1800)},
            {"type": "reasoning", "run_id": "r2", "thought": "archaeology", "cmd": "traj tail", "llm_s": 60, "ts": ts(1790)},
            {"type": "run-end", "run_id": "r2", "rc": 1, "ts": ts(1700)},
            {"type": "shellm-run", "step_id": "s1", "launched_by": "social", "ts": ts(900)},
            {"type": "message", "run_id": "s1", "from": "custos", "to": "signal-group", "content": "hi", "ts": ts(890)},
            {"type": "message", "from": "custos", "to": "square:egress:1:2", "content": "reply", "ts": ts(800)},
            {"type": "message", "from": "custos", "to": "square:egress:1:3", "content": "reply", "ts": ts(700)},
            {"type": "observation", "source": "square-outbox", "content": "Public square reply delivered: {}", "ts": ts(600)},
            {"type": "observation", "source": "responder", "decision": "replied", "ts": ts(500)},
            {"type": "observation", "source": "responder", "decision": "replied", "deferred": True, "ts": ts(400)},
            {"type": "observation", "source": "responder", "decision": "no-reply", "ts": ts(300)},
            {"type": "observation", "source": "responder", "decision": "reply-failed", "ts": ts(200)},
            {"type": "observation", "source": "goals", "request_id": "custos-resolve:abc", "content": "done", "ts": ts(100)},
            {"type": "message", "from": "custos", "to": "square:old:1:1", "content": "old", "ts": ts(90000)},  # outside the window
        ]
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "trajectory.jsonl"
            path.write_text("".join(json.dumps(r) + "\n" for r in rows))
            m = self_metrics(path, now)
        self.assertEqual(m["metrics_schema_version"], 2)
        self.assertEqual((m["monolith_wakes"], m["monolith_completed_wakes"], m["monolith_open_wakes"]), (2, 2, 0))
        self.assertEqual((m["monolith_known_rc_wakes"], m["monolith_unknown_rc_wakes"], m["monolith_rc_nonzero_pct"]), (2, 0, 50))
        self.assertEqual(m["monolith_first_durable_p50"], 2)
        self.assertEqual((m["monolith_completed_final_only_wakes"], m["monolith_completed_other_durable_wakes"]), (0, 1))
        self.assertEqual((m["truncation_thought_pct"], m["self_read_cmd_pct"]), (67, 67))
        self.assertEqual((m["square_composed"], m["square_delivered"]), (2, 1))
        self.assertEqual((m["signal_sent"], m["signal_sent_by_social"], m["social_runs"]), (1, 1, 1))
        self.assertEqual(m["responder"], {"replied": 2, "no-reply": 1, "deferred": 1, "failed": 1})
        self.assertEqual((m["goals_opened"], m["goals_closed"]), (1, 1))
        self.assertEqual(m["inference_hours"], round(120 / 3600, 2))
        text = metrics_text(m, {**m, "square_delivered": 0, "monolith_wakes": 5})
        self.assertIn("2 monolith wakes (-3) (observed starts), 2 ended wakes, 0 wakes with no run-end observed", text)
        self.assertIn("known rc / 0 with unknown rc", text)
        self.assertIn("2 composed / 1 delivered (+1)", text)
        self.assertIn("A composed reply is not a delivered one", text)
        self.assertNotIn("bought nothing", text)
        self.assertNotIn("how long you take to start", text)

    def test_metrics_completed_only_and_final_is_a_marker(self):
        from custos_observe import self_metrics
        now = 1788960000.0

        def ts(ago):
            import time as _t
            return _t.strftime("%Y-%m-%dT%H:%M:%S.000Z", _t.gmtime(now - ago))

        rows = [
            # This high-iteration start has no end record and must not affect
            # completed-run percentiles or cap/no-marker counts.
            {"type": "shellm-run", "step_id": "open", "launched_by": "monolith", "ts": ts(500)},
            *[{"type": "reasoning", "run_id": "open", "llm_s": 1, "ts": ts(499 - n)} for n in range(200)],
            {"type": "shellm-run", "step_id": "observed", "launched_by": "monolith", "ts": ts(400)},
            {"type": "reasoning", "run_id": "observed", "llm_s": 1, "ts": ts(399)},
            {"type": "reasoning", "run_id": "observed", "llm_s": 1, "ts": ts(398)},
            {"type": "observation", "run_id": "observed", "source": "test", "ts": ts(397)},
            {"type": "run-end", "run_id": "observed", "rc": 0, "ts": ts(396)},
            # A final before a zero-code end is a durable marker, but not success evidence.
            {"type": "shellm-run", "step_id": "final-only", "launched_by": "monolith", "ts": ts(350)},
            *[{"type": "reasoning", "run_id": "final-only", "llm_s": 1, "ts": ts(349 - n)} for n in range(5)],
            {"type": "final", "run_id": "final-only", "ts": ts(340)},
            {"type": "run-end", "run_id": "final-only", "rc": 0, "ts": ts(339)},
            {"type": "shellm-run", "step_id": "unlogged-failure", "launched_by": "monolith", "ts": ts(300)},
            {"type": "reasoning", "run_id": "unlogged-failure", "llm_s": 1, "ts": ts(299)},
            {"type": "run-end", "run_id": "unlogged-failure", "rc": 7, "ts": ts(298)},
            {"type": "shellm-run", "step_id": "unknown-rc", "launched_by": "monolith", "ts": ts(250)},
            *[{"type": "reasoning", "run_id": "unknown-rc", "llm_s": 1, "ts": ts(249 - n)} for n in range(3)],
            {"type": "observation", "run_id": "unknown-rc", "source": "test", "ts": ts(245)},
            {"type": "run-end", "run_id": "unknown-rc", "ts": ts(244)},
        ]
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "trajectory.jsonl"
            path.write_text("".join(json.dumps(row) + "\n" for row in rows))
            m = self_metrics(path, now)

        self.assertEqual((m["monolith_wakes"], m["monolith_completed_wakes"], m["monolith_open_wakes"]), (5, 4, 1))
        self.assertEqual((m["monolith_known_rc_wakes"], m["monolith_unknown_rc_wakes"]), (3, 1))
        self.assertEqual(m["monolith_rc_nonzero_pct"], 33)
        self.assertEqual((m["monolith_iterations_p50"], m["monolith_iterations_p90"]), (3, 5))
        self.assertEqual(m["monolith_first_durable_p50"], 3)
        self.assertEqual((m["monolith_no_durable_step"], m["monolith_at_cap"]), (1, 0))
        self.assertEqual((m["monolith_completed_final_only_wakes"], m["monolith_completed_other_durable_wakes"]), (1, 2))

    def test_metrics_all_open_and_empty_have_no_completed_denominators(self):
        from custos_observe import self_metrics, metrics_text
        now = 1788960000.0

        def ts(ago):
            import time as _t
            return _t.strftime("%Y-%m-%dT%H:%M:%S.000Z", _t.gmtime(now - ago))

        open_rows = [
            {"type": "shellm-run", "step_id": "open-a", "launched_by": "monolith", "ts": ts(30)},
            *[{"type": "reasoning", "run_id": "open-a", "ts": ts(29)} for _ in range(200)],
            {"type": "shellm-run", "step_id": "open-b", "launched_by": "monolith", "ts": ts(20)},
            {"type": "final", "run_id": "open-b", "ts": ts(19)},
        ]
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "trajectory.jsonl"
            path.write_text("".join(json.dumps(row) + "\n" for row in open_rows))
            open_metrics = self_metrics(path, now)
            path.write_text("")
            empty_metrics = self_metrics(path, now)

        for metrics, starts in ((open_metrics, 2), (empty_metrics, 0)):
            self.assertEqual(metrics["metrics_schema_version"], 2)
            self.assertEqual((metrics["monolith_wakes"], metrics["monolith_completed_wakes"], metrics["monolith_open_wakes"]), (starts, 0, starts))
            self.assertEqual((metrics["monolith_known_rc_wakes"], metrics["monolith_unknown_rc_wakes"]), (0, 0))
            self.assertEqual((metrics["monolith_rc_nonzero_pct"], metrics["monolith_iterations_p50"], metrics["monolith_iterations_p90"]), (0, 0, 0))
            self.assertEqual((metrics["monolith_first_durable_p50"], metrics["monolith_no_durable_step"], metrics["monolith_at_cap"]), (0, 0, 0))
            self.assertEqual((metrics["monolith_completed_final_only_wakes"], metrics["monolith_completed_other_durable_wakes"]), (0, 0))

        text = metrics_text(open_metrics)
        self.assertIn("2 monolith wakes (observed starts), 0 ended wakes, 2 wakes with no run-end observed", text)
        self.assertIn("known-rc ended wakes", text)
        self.assertIn("logging, not work start or value", text)
        self.assertNotIn("bought nothing", text)
        self.assertNotIn("how long you take to start", text)

    def test_observer_emits_daily_metrics_once_and_keeps_yesterday(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        store = Store(temp.name); self.addCleanup(store.db.close)
        traj = Path(temp.name) / "traj.jsonl"; traj.write_text("")
        native = NativeFixture(); native.path = traj
        observer = Observer({}, store, None, native, now=1788960000.0)
        observer.source("self-metrics", 86400, observer.daily_metrics)
        observer.source("self-metrics", 86400, observer.daily_metrics)
        self.assertEqual([k for k in native.messages if k.startswith("metrics:")], ["metrics:2026-09-09"])
        self.assertIn("Daily self-metrics", native.messages["metrics:2026-09-09"]["content"])
        self.assertIsNotNone(store.get("metrics:latest"))


class ScheduleTests(unittest.TestCase):
    """Weekly operator schedules: one wake per slot, local time, no catch-up flood."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = Store(self.temp.name)
        self.addCleanup(self.store.db.close)
        self.native = NativeFixture()
        self.config = {"schedules": [{"name": "mealplan-monday", "weekday": "monday", "at": "09:00",
                                      "tz": "America/Denver", "content": "Plan next week's dinners."}]}

    def run_at(self, iso):
        from datetime import datetime
        now = datetime.fromisoformat(iso).timestamp()
        observer = Observer(self.config, self.store, None, self.native, now=now)
        observer.source("schedules", 60, observer.schedules)
        return observer

    def emitted(self):
        return [k for k in self.native.messages if k.startswith("schedule:")]

    def test_fires_once_at_or_after_the_slot_and_never_before(self):
        self.run_at("2026-09-14T08:59:00-06:00")  # Monday, one minute early
        self.assertEqual(self.emitted(), [])
        self.run_at("2026-09-14T09:03:00-06:00")
        self.assertEqual(self.emitted(), ["schedule:mealplan-monday:2026-09-14T09:00"])
        envelope = self.native.messages["schedule:mealplan-monday:2026-09-14T09:00"]
        self.assertEqual(envelope["authority"], "operator")
        self.assertIn("Monday 2026-09-14 09:00 MDT", envelope["content"])
        self.assertIn("Plan next week's dinners.", envelope["content"])
        self.run_at("2026-09-14T09:30:00-06:00")  # same slot again: no duplicate
        self.run_at("2026-09-15T09:30:00-06:00")  # Tuesday: nothing
        self.assertEqual(len(self.emitted()), 1)

    def test_next_week_is_a_new_slot(self):
        self.run_at("2026-09-14T09:03:00-06:00")
        self.run_at("2026-09-21T09:03:00-06:00")
        self.assertEqual(self.emitted(), ["schedule:mealplan-monday:2026-09-14T09:00",
                                          "schedule:mealplan-monday:2026-09-21T09:00"])

    def test_a_slot_missed_beyond_grace_is_recorded_not_replayed(self):
        self.run_at("2026-09-14T16:00:01-06:00")  # 7 h late, default grace 6 h
        self.assertEqual(self.emitted(), [])
        self.assertTrue(self.store.seen("schedule:mealplan-monday:2026-09-14T09:00"))
        row = self.store.db.execute("SELECT disposition FROM seen WHERE id=?", ("schedule:mealplan-monday:2026-09-14T09:00",)).fetchone()
        self.assertEqual(row[0], "schedule_missed")

    def test_disabled_and_dst_and_utc_slots(self):
        self.config["schedules"][0]["enabled"] = False
        self.run_at("2026-09-14T09:03:00-06:00")
        self.assertEqual(self.emitted(), [])
        self.config["schedules"] = [{"name": "friday-order", "weekday": "Fri", "at": "09:00", "tz": "America/Denver", "content": "Order."}]
        self.run_at("2026-11-06T09:02:00-07:00")  # after the DST change: 09:00 MST is still 09:00 local
        self.assertEqual(self.emitted(), ["schedule:friday-order:2026-11-06T09:00"])


class _Headers:
    def __init__(self, mapping):
        self._mapping = mapping
    def get(self, k, default=None):
        return self._mapping.get(k, default)


class _FakeResponse:
    def __init__(self, raw, content_encoding=None):
        self.raw = raw
        self.headers = _Headers({"Content-Encoding": content_encoding} if content_encoding else {})
        self.status = 200
    def read(self, n=None):
        return self.raw
    def __enter__(self):
        return self
    def __exit__(self, *a):
        return False


class PublicRequestTests(unittest.TestCase):
    """public_request must return the decoded payload, not the wire bytes.

    The UN CDN force-gzips (Content-Encoding: gzip) without an
    Accept-Encoding; undecoded, ET.fromstring chokes on the gzip magic and
    the source fails every interval (un-news, 2026-09-22).
    """

    def _response(self, raw, content_encoding=None):
        return _FakeResponse(raw, content_encoding)

    def test_forced_gzip_is_decoded(self):
        body = b'<rss><channel><item><guid>one</guid><title>One</title></item></channel></rss>'
        with patch("custos_square.urllib.request.build_opener") as opener:
            opener.return_value.open.return_value = self._response(gzip.compress(body), "gzip")
            raw, tag, status = public_request("https://news.un.invalid/rss")
        self.assertEqual(status, 200)
        self.assertEqual(raw, body)
        ET.fromstring(raw)

    def test_plain_body_passes_through(self):
        body = b'{"ok":true}'
        with patch("custos_square.urllib.request.build_opener") as opener:
            opener.return_value.open.return_value = self._response(body)
            raw, tag, status = public_request("https://1f916.invalid/api")
        self.assertEqual(raw, body)

    def test_corrupt_gzip_is_content_encoding_unreadable(self):
        with patch("custos_square.urllib.request.build_opener") as opener:
            opener.return_value.open.return_value = self._response(b"\x1f\x8b\x08nope", "gzip")
            with self.assertRaises(APIError) as ctx:
                public_request("https://news.un.invalid/rss")
        self.assertEqual(ctx.exception.code, "content_encoding_unreadable")
