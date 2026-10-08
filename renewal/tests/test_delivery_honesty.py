"""Regressions from the 2026-09-11 audit: messages the guest booked as delivered
that never left it, a memory rewrite the reader could not parse, duplicate
person notes, and the summary/search defects behind a stale re-raise.

Real native chat/mem/traj in temporary identities; llm and custos-actions are
replaced by fakes on PATH. No model, network or service calls.
"""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import custos_memory as cm
import custos_transport as ct
from test_memory import HEADLONG, MemoryFixture

RENEWAL = Path(__file__).resolve().parents[1]
UUID_A = "aaaaaaaa-1111-4111-8111-111111111111"
UUID_B = "bbbbbbbb-2222-4222-8222-222222222222"


def now_iso(offset=0):
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() + offset))


def route_for(target):
    return "signal-" + hashlib.sha256(target.encode()).hexdigest()[:24]


def executable(path, body):
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class ChatFixture(unittest.TestCase):
    def setUp(self):
        self.temp = unittest.mock.MagicMock()
        import tempfile
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.root = Path(self.tempdir.name)
        self.identity = self.root / "identity"
        self.traj_id = "cafe0000-0000-0000-0000-0000000000ee"
        self.traj_dir = self.identity / "trajectories" / self.traj_id
        self.traj_dir.mkdir(parents=True)
        (self.identity / "memories").mkdir()
        self.log = self.traj_dir / "trajectory.jsonl"
        self.log.write_text(cm.encode({"type": "trajectory", "step_id": "header-1", "ts": now_iso(-7200)}) + "\n")
        self.fake_bin = self.root / "fakebin"
        self.fake_bin.mkdir()
        self.env = mock.patch.dict(os.environ, {
            "IDENTITY_DIR": str(self.identity), "IDENTITY_NAME": "custos", "MEM_DIR": str(self.identity / "memories"),
            "TRAJ_DIR": str(self.identity / "trajectories"), "TRAJ_ID": self.traj_id, "ROOT_TRAJ_ID": self.traj_id,
            "PATH": str(self.fake_bin) + ":" + str(HEADLONG / "bin") + ":" + str(HEADLONG / "tools") + ":" + os.environ["PATH"],
            "HOME": str(self.root / "home"), "CHAT_DOUBLE_TEXT_GUARD_HOURS": "", "CHAT_SOCIAL_BLOCKED": ""})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.contact = "dm:bob-aci"
        self.bob = route_for(self.contact)
        self.alice = "signal-aaaaaaaaaaaaaaaaaaaaaaaa"
        # The host is fake, but the guard decision is the real implementation.
        # Fixture messages below have explicit successful transport receipts.
        executable(self.fake_bin / "custos-actions", self.guard_stub() + "sys.exit(2)\n")

    def guard_stub(self):
        return ("#!/usr/bin/env python3\nimport json, sys, os, time\nfrom pathlib import Path\n"
                "sys.path.insert(0," + repr(str(RENEWAL)) + ")\n"
                "if sys.argv[1] == 'signal-guard':\n"
                "    import custos_contact_guard as g\n"
                "    rows=[json.loads(l) for l in Path(" + repr(str(self.log)) + ").read_text().splitlines()]\n"
                "    route=sys.argv[2]; aci=next((g.metadata(r,'aci') for r in rows if r.get('from')==route and g.metadata(r,'aci')), 'fixture')\n"
                "    def receipt(ref):\n"
                "        row=next((r for r in rows if g.reference(r)==ref), {})\n"
                "        return {'phase':'submitted','receipt':{'timestamp':g.timestamp(row['ts']),'results':[{'type':'SUCCESS'}]}}\n"
                "    result=g.evaluate(rows,'dm:'+aci,route,int(os.environ.get('CHAT_DOUBLE_TEXT_GUARD_HOURS') or 2),os.environ.get('CHAT_GUARD_CROSS_ROOM')=='1',receipt,time.time())\n"
                "    print(json.dumps(result));sys.exit(0 if result['ok'] else 1)\n")

    def append(self, step):
        step = dict(step)
        step.setdefault("ts", now_iso())
        with self.log.open("a") as handle:
            handle.write(cm.encode(step) + "\n")

    def inbound(self, route, step_id, content="hello", receipt=True, request_id=None):
        request_id = request_id or "signal:" + hashlib.sha256((route + step_id).encode()).hexdigest()
        self.append({"type": "message", "step_id": step_id, "from": route, "to": "custos", "source": "operator-transport",
                     "request_id": request_id, "authority": "external", "content": content})
        if receipt:
            state = self.identity / ".state" / "transport"
            state.mkdir(parents=True, exist_ok=True)
            key = hashlib.sha256(request_id.encode()).hexdigest()
            (state / (key + ".json")).write_text(json.dumps({
                "original": {"request_id": request_id, "sender": route, "authority": "external", "source_url": "", "content": content},
                "step_id": step_id, "phase": "queued", "reply_offset": 0}))
        return request_id

    def steps(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def outgoing(self):
        return [s for s in self.steps() if s.get("type") == "message" and s.get("from") == "custos"]

    def chat(self, *args, stdin=None):
        return subprocess.run(["chat", *args], input=stdin, text=True, capture_output=True, timeout=120)

    def fake_actions(self, contacts):
        log = self.root / "actions.log"
        argv_log = self.root / "actions.argv"
        executable(self.fake_bin / "custos-actions", self.guard_stub() +
                   "if sys.argv[1] == 'signal-contacts':\n    print(json.dumps({'ok': True, 'contacts': " + repr(contacts) + "})); sys.exit(0)\n"
                   "if sys.argv[1] == 'signal-send':\n    raw = sys.stdin.read(); open(" + repr(str(log)) + ", 'a').write(raw + '\\n')\n"
                   "    open(" + repr(str(argv_log)) + ", 'a').write(json.dumps(sys.argv[1:]) + '\\n')\n"
                   "    print(json.dumps({'ok': True, 'request_id': json.loads(raw)['request_id'], 'phase': 'queued'})); sys.exit(0)\n"
                   "sys.exit(2)\n")
        return log


class ChatOutboundTests(ChatFixture):
    def test_reply_to_prefix_resolves_to_the_delivered_message_and_is_queued_for_the_bridge(self):
        self.inbound(self.alice, UUID_A, "what is the plan?")
        result = self.chat("reply", "--follow-up", "--reply-to", UUID_A[:8], self.alice, "here is the plan")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("queued for the Signal bridge as a reply to " + UUID_A[:8], result.stderr)
        sent = self.outgoing()
        self.assertEqual(len(sent), 1)
        self.assertEqual(sent[0]["reply_to"], UUID_A, "the prefix must be stamped as the full step id the bridge knows")
        self.assertEqual(sent[0]["to"], self.alice)

    def test_reply_to_ambiguous_prefix_is_refused(self):
        self.inbound(self.alice, "abcd0000-1111-4111-8111-111111111111", "one")
        self.inbound(self.alice, "abcd0000-2222-4222-8222-222222222222", "two")
        result = self.chat("reply", "--follow-up", "--reply-to", "abcd0000", self.alice, "which?")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("more than one message step", result.stderr)
        self.assertEqual(self.outgoing(), [])

    def test_display_name_is_not_a_route(self):
        self.inbound(self.alice, UUID_A, "hi from a route the log knows")
        result = self.chat("reply", "--follow-up", "--reply-to", UUID_A, "Hal", "Your guess was right")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not sent", result.stderr)
        self.assertIn("display name is not a route", result.stderr)
        self.assertEqual(self.outgoing(), [])

    def test_signal_route_without_a_delivered_message_goes_through_custos_actions(self):
        log = self.fake_actions([{"target": self.contact, "label": "Bob", "kind": "dm"}])
        # Bob has spoken (so the route is known) but the reply names nothing the bridge delivered.
        self.inbound(self.bob, UUID_B, "earlier chatter", receipt=False)
        result = self.chat("send", "--from", "custos", "--to", self.bob, "Napa is on the list")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Recorded through custos-actions", result.stderr)
        self.assertNotIn("Sent through custos-actions", result.stderr)
        self.assertEqual(self.outgoing(), [], "custos-actions records the step; chat must not append a second one")
        payload = json.loads(log.read_text().strip().splitlines()[-1])
        self.assertEqual(payload["target"], self.contact)
        self.assertEqual(payload["message"], "Napa is on the list")
        self.assertTrue(payload["request_id"].startswith("chat-"))

    def test_signal_route_the_broker_cannot_reach_is_refused_not_booked(self):
        self.fake_actions([{"target": "dm:someone-else", "label": "Else", "kind": "dm"}])
        self.inbound(self.bob, UUID_B, "earlier chatter", receipt=False)
        result = self.chat("reply", "--follow-up", "--reply-to", UUID_B, self.bob, "That actually did ring a bell")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not sent", result.stderr)
        self.assertIn("bridge only carries replies", result.stderr)
        self.assertEqual(self.outgoing(), [])

    def test_signal_send_file_uses_attachment_broker_and_never_raw_native_append(self):
        log = self.fake_actions([{"target": self.contact, "label": "Bob", "kind": "dm"}])
        self.inbound(self.bob, UUID_B, "send the report", receipt=True)
        report = self.root / "report.txt"
        report.write_text("verified report")
        result = self.chat("send-file", "--from", "custos", "--to", self.bob,
                           "--reply-to", UUID_B[:8], "--caption", "Here it is.", str(report))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("receipt-bearing request", result.stderr)
        self.assertEqual(self.outgoing(), [])
        payload = json.loads(log.read_text().strip().splitlines()[-1])
        self.assertEqual((payload["target"], payload["message"]), (self.contact, "Here it is."))
        argv = json.loads((self.root / "actions.argv").read_text().splitlines()[-1])
        self.assertEqual(argv, ["signal-send", "--attach", str(report), "--reply-to", UUID_B[:8]])

    def test_signal_send_file_refusal_is_not_reported_as_delivery(self):
        self.fake_actions([{"target": "dm:someone-else", "label": "Else", "kind": "dm"}])
        report = self.root / "report.txt"
        report.write_text("contents")
        result = self.chat("send-file", "--from", "custos", "--to", self.bob, str(report))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not sent", result.stderr)
        self.assertNotIn("File sent", result.stderr)
        self.assertEqual(self.outgoing(), [])

    def test_follow_up_delivery_is_exempt_from_the_double_text_guard(self):
        self.inbound(self.alice, UUID_A, "can you build it?")
        # The identity spoke last (a nudge of its own, answering nothing) and Alice has not replied.
        self.append({"type": "message", "step_id": "custos-said-1", "from": "custos", "to": self.alice,
                     "content": "still there?", "source": "chat"})
        with mock.patch.dict(os.environ, {"CHAT_DOUBLE_TEXT_GUARD_HOURS": "2"}):
            plain = self.chat("reply", "--reply-to", UUID_A, self.alice, "just checking in again")
            self.assertNotEqual(plain.returncode, 0)
            self.assertIn("you spoke last", plain.stderr)
            self.assertRegex(plain.stderr, r"reopens at \d{4}-\d{2}-\d{2}T\d\d:\d\d:")
            self.assertIn("do not sleep, loop or poll", plain.stderr)
            self.assertEqual([s["content"] for s in self.outgoing()], ["still there?"])
            delivery = self.chat("reply", "--follow-up", "--reply-to", UUID_A, self.alice, "Built. Here it is.")
            self.assertEqual(delivery.returncode, 0, delivery.stderr)
        self.assertEqual([s["content"] for s in self.outgoing()][-1], "Built. Here it is.")

    def test_inbound_direction_is_untouched(self):
        result = self.chat("send", "--from", "alice-phone", "--to", "custos", "a message to the identity")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.steps()[-1]["from"], "alice-phone")


class TransportPrefixTests(unittest.TestCase):
    def test_receipt_lookup_accepts_a_unique_prefix_and_refuses_an_ambiguous_one(self):
        receipts = {UUID_A: "signal:one", UUID_B: "signal:two", "aaaaaaaa-9999-4999-8999-999999999999": "signal:three"}
        self.assertEqual(ct.receipt_lookup(receipts, UUID_A), "signal:one")
        self.assertEqual(ct.receipt_lookup(receipts, "bbbbbbbb"), "signal:two")
        self.assertIsNone(ct.receipt_lookup(receipts, "aaaaaaaa"), "two receipts share the prefix")
        self.assertIsNone(ct.receipt_lookup(receipts, "aa"))
        self.assertIsNone(ct.receipt_lookup(receipts, ""))
        self.assertIsNone(ct.receipt_lookup(receipts, None))


class StoreValidationTests(MemoryFixture):
    def setUp(self):
        super().setUp()
        self.identity = self.root / "identity"
        self.traj_id = "cafe0000-0000-0000-0000-0000000000dd"
        self.traj_dir = self.identity / "trajectories" / self.traj_id
        self.traj_dir.mkdir(parents=True)
        self.log = self.traj_dir / "trajectory.jsonl"
        self.log.write_text(cm.encode({"type": "trajectory", "step_id": "header", "ts": "2020-01-01T00:00:00.000Z"}) + "\n")
        self.native_env = mock.patch.dict(os.environ, {"IDENTITY_DIR": str(self.identity), "IDENTITY_NAME": "custos",
                                                      "TRAJ_DIR": str(self.identity / "trajectories"),
                                                      "TRAJ_ID": self.traj_id, "ROOT_TRAJ_ID": self.traj_id})
        self.native_env.start()
        self.addCleanup(self.native_env.stop)

    def envelope(self, step_id, content):
        return {"type": "message", "step_id": step_id, "from": "signal-route-1", "to": "custos", "request_id": "signal:" + step_id,
                "authority": "external", "source_url": "", "content": content, "ts": "2020-01-01T00:00:01.000Z"}

    def append(self, step):
        with self.log.open("a") as handle:
            handle.write(cm.encode(step) + "\n")

    def steps(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_reconcile_sets_conflicting_records_aside_in_one_observation_not_a_note_each(self):
        for n in range(3):
            step = self.envelope("step-%d" % n, "original text %d" % n)
            self.append(step)
            self.store.capture(*cm.envelope_payload(step))
        # A rewrite changes the captured provenance of every record (the density-floor pass, 2026-09-11).
        for path, header, body, fields, record in list(self.store.files()):
            record["origin"]["content"] = "[collapsed]"
            self.store.save((path, header, body, fields, record), record)
        self.store.reconcile()
        notes = [f for f in self.store.files() if "Unusable incoming" in f[2]]
        self.assertEqual(notes, [], "no junk note per rejected step")
        state = json.loads((self.identity / ".state" / "ingress-rejected.json").read_text())
        self.assertEqual(sorted(e["step_id"] for e in state), ["step-0", "step-1", "step-2"])
        observations = [s for s in self.steps() if s.get("type") == "observation" and s.get("source") == "custos-memory"]
        self.assertEqual(len(observations), 1)
        self.assertIn("3 incoming messages could not be matched", observations[0]["content"])
        self.assertIn("custos-memory validate", observations[0]["content"])
        # Idempotent: a second pass records nothing new.
        self.store.reconcile()
        self.assertEqual(len([s for s in self.steps() if s.get("source") == "custos-memory"]), 1)
        self.assertEqual(len(json.loads((self.identity / ".state" / "ingress-rejected.json").read_text())), 3)

    def test_validate_reports_conflicts_and_unparseable_files_without_writing(self):
        step = self.envelope("step-9", "keep me")
        self.append(step)
        goal_id = self.store.capture(*cm.envelope_payload(step))["goal_id"]
        clean = self.store.validate()
        self.assertEqual((clean["problems"], clean["conflicts"]), ([], []))
        item = self.store.find(goal_id)
        record = item[4]
        record["origin"]["content"] = "[collapsed]"
        self.store.save(item, record)
        broken = self.root / "memories" / "2020-01-01-00-00-00_deadbeef_broken.md"
        broken.write_text("---\nid: deadbeef\nsummary: x\ntype: memory\ncreated: 2020-01-01 00:00:00\n---\n\nx" + cm.MARKER + '{"version":1,"status":"bogus"}\n')
        before = {p.name: p.read_bytes() for p in (self.root / "memories").glob("*.md")}
        result = self.store.validate()
        self.assertEqual([c["step_id"] for c in result["conflicts"]], ["step-9"])
        self.assertEqual(result["conflicts"][0]["differs"], ["content"])
        self.assertEqual([p["file"] for p in result["problems"]], [broken.name])
        self.assertEqual(before, {p.name: p.read_bytes() for p in (self.root / "memories").glob("*.md")})
        single = self.store.validate([str(broken)])
        self.assertEqual(single["checked"], 1)
        self.assertEqual(len(single["problems"]), 1)

    def test_validate_command_exit_status_and_mem_edit_hook(self):
        env = dict(os.environ, PATH=str(RENEWAL / "bin") + ":" + os.environ["PATH"])
        run = lambda *args, **kw: subprocess.run(list(args), env=env, text=True, capture_output=True, timeout=120, **kw)
        good = run("mem", "add", "--type", "memory", "Observed conversation: hi" + cm.MARKER + cm.encode({
            "version": 1, "origin": {"request_id": "r1", "sender": "s", "source_url": "", "content": "c", "authority": "external"},
            "goal": {"outcome": "o", "next_action": "n", "completion": "c"}, "status": "active", "events": [], "response": None}))
        self.assertEqual(good.returncode, 0, good.stderr)
        bad = run("mem", "add", "--type", "memory", "Observed conversation: hi" + cm.MARKER + '{"version":1,"status":"bogus"}')
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn("write refused", bad.stderr)
        self.assertEqual([p.name for p in (self.root / "memories").glob("*bogus*")], [])
        self.assertEqual(len(list((self.root / "memories").glob("*.md"))), 1)
        stem = good.stdout.strip()
        original = (self.root / "memories" / (stem + ".md")).read_text()
        edit = run("mem", "edit", stem.split("_")[1], "Observed conversation: rewritten" + cm.MARKER + '{"version":1,"status":"bogus"}')
        self.assertNotEqual(edit.returncode, 0)
        self.assertIn("record restored", edit.stderr)
        self.assertEqual((self.root / "memories" / (stem + ".md")).read_text(), original)
        verdict = run("custos-memory", "validate")
        self.assertEqual(verdict.returncode, 0, verdict.stdout + verdict.stderr)
        (self.root / "memories" / "2020-01-01-00-00-00_deadbeef_broken.md").write_text(
            "---\nid: deadbeef\nsummary: x\ntype: memory\ncreated: 2020-01-01 00:00:00\n---\n\nx" + cm.MARKER + '{"version":1,"status":"bogus"}\n')
        verdict = run("custos-memory", "validate")
        self.assertEqual(verdict.returncode, 1)
        self.assertIn("deadbeef", verdict.stdout)


class NativeMemTests(MemoryFixture):
    def mem(self, *args, stdin=None):
        return subprocess.run(["mem", *args], input=stdin, text=True, capture_output=True, timeout=120)

    def read(self, stem):
        files = list((self.root / "memories").glob("*" + stem.split("_")[1] + "*"))
        self.assertEqual(len(files), 1)
        return files[0].read_text()

    def test_summary_is_the_first_non_blank_line_and_leading_blanks_are_dropped(self):
        added = self.mem("add", "--type", "note", stdin="\n\nPerson: Ryan\n\nlikes riddles\n")
        self.assertEqual(added.returncode, 0, added.stderr)
        text = self.read(added.stdout.strip())
        self.assertIn("summary: Person: Ryan\n", text)
        self.assertTrue(text.split("---\n", 2)[2].startswith("\nPerson: Ryan"), text)
        edited = self.mem("edit", added.stdout.strip().split("_")[1], stdin="\n\n\nPerson: Ryan (edited)\nstill likes riddles\n")
        self.assertEqual(edited.returncode, 0, edited.stderr)
        text = self.read(added.stdout.strip())
        self.assertIn("summary: Person: Ryan (edited)\n", text)
        self.assertNotIn("summary: \n", text)

    def test_search_drops_result_lines_naming_memories_that_do_not_exist(self):
        added = self.mem("add", "--type", "fact", "Ryan called Custos a chopped idiot and apologized")
        real = added.stdout.strip()
        fake_bin = self.root / "fakebin"
        fake_bin.mkdir()
        executable(fake_bin / "llm", "#!/usr/bin/env bash\nsys=$(cat >/dev/null)\n"
                   "printf '%s\\n' '" + real + " — the apology' '2026-01-01-00-00-00_deadbeef_ghost-record — invented' 'No other matches.'\n")
        with mock.patch.dict(os.environ, {"PATH": str(fake_bin) + ":" + os.environ["PATH"], "MEM_SEARCH_HEARTBEAT_S": "0"}):
            result = self.mem("search", "chopped idiot")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(real, result.stdout)
        self.assertNotIn("deadbeef", result.stdout)
        self.assertIn("No other matches.", result.stdout)
        self.assertIn("dropped 1 result line", result.stderr)


class PeopleTests(MemoryFixture):
    def note(self, display, notes, updated, aliases=()):
        meta = {"person_key": "signal:jack-aci", "display": display, "aliases": list(aliases), "routes": ["signal-g"], "updated": updated}
        body = "Person: " + display + "\n\n" + notes + cm.PERSON_MARKER + cm.encode(meta)
        return self.store.commit(body, memory_type="person")

    def test_find_prefers_the_most_recently_updated_duplicate_and_merge_folds_them(self):
        older = self.note("Jack", "Hal's friend; likes riddles.", "2026-09-10T20:22:00+00:00", aliases=["Friend (group admin)"])
        newer = self.note("Jack", "Playful, probing; the human behind Kim.", "2026-09-11T05:39:00+00:00")
        people = cm.People(self.store)
        self.assertEqual(len(people.find_all("signal:jack-aci")), 2)
        self.assertIn("behind Kim", people.find("signal:jack-aci")[2])
        result = people.merge(newer, older)
        self.assertEqual(result["kept"], older)
        self.assertEqual(result["merged"], newer)
        self.assertEqual(len(people.find_all("signal:jack-aci")), 1)
        kept = people.find("signal:jack-aci")
        self.assertIn("likes riddles", kept[2])
        self.assertIn("behind Kim", kept[2])
        self.assertEqual(kept[1]["aliases"], ["Friend (group admin)"])
        self.assertEqual(kept[1]["display"], "Jack")
        archived = self.root / "dream" / "operator-cleanup"
        self.assertEqual(len(list((archived / "changes").glob("*.before.md"))), 2)
        self.assertEqual(len(list((archived / "merged").glob("*.md"))), 1)

    def test_merge_refuses_two_different_people(self):
        a = self.note("Jack", "one", "2026-09-10T00:00:00+00:00")
        body = "Person: Kim\n\nbot" + cm.PERSON_MARKER + cm.encode({"person_key": "signal:kim-aci", "display": "Kim", "aliases": [], "routes": [], "updated": "x"})
        b = self.store.commit(body, memory_type="person")
        with self.assertRaises(cm.MemoryError):
            cm.People(self.store).merge(a, b)
        self.assertEqual(len(list((self.root / "memories").glob("*.md"))), 2)



class OutboxDrainTests(unittest.TestCase):
    """The square outbox drain reads to the end of the log in one pass (bounded by
    time and bytes), so stale rows at the head clear at the reset instead of a
    few per tick: on 2026-09-11 the old 300-line cap turned 53 free drops into a
    2 h 18 min crawl and aged two fresh replies past the freshness cap."""

    def setUp(self):
        import tempfile
        from custos_observe import Observer
        from custos_square import Store
        from test_observations import NativeFixture
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = Store(self.temp.name)
        self.addCleanup(self.store.db.close)
        self.native = NativeFixture()
        self.path = Path(self.temp.name) / "traj.jsonl"
        self.native.path = self.path
        self.now = 1789171200.0  # 2026-09-12T00:00:00Z

        class SquareStub:
            written = []

            def get(_, path, query=None, auth=False):
                return {"comment": {"author": "peer"}, "post": {"author": "peer"}}

            def write(_, identity, verb, payload):
                SquareStub.written.append((identity, payload))
                return {"request_id": identity, "status": "delivered", "readback": "https://1f916.ai/api/comment/1"}

        self.square = SquareStub()
        self.observer = Observer({}, self.store, self.square, self.native, now=self.now)

    def stamp(self, seconds_ago):
        return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(self.now - seconds_ago))

    def write_log(self, filler=400):
        lines = [cm.encode({"type": "trajectory", "step_id": "header"})]
        lines += [cm.encode({"type": "reasoning", "step_id": "r%d" % n, "thought": "x" * 200}) for n in range(filler)]
        lines.append(cm.encode({"type": "message", "step_id": "stale-1", "from": "custos", "to": "square:peer:10:99",
                                "content": "a day-old take", "ts": self.stamp(20 * 3600)}))
        lines += [cm.encode({"type": "reasoning", "step_id": "s%d" % n, "thought": "y" * 200}) for n in range(filler)]
        lines.append(cm.encode({"type": "message", "step_id": "fresh-1", "from": "custos", "to": "square:peer:10:100",
                                "content": "a fresh reply", "ts": self.stamp(3600)}))
        self.path.write_text("\n".join(lines) + "\n")

    def test_one_pass_drops_the_stale_head_and_delivers_the_fresh_reply(self):
        self.write_log()
        cursor = {"path": str(self.path), "offset": 0}
        self.observer._drain_outbox(self.path, cursor)
        self.assertIn("stale:stale-1", self.native.messages)
        self.assertIn("dropped undelivered", self.native.messages["stale:stale-1"]["content"])
        self.assertIn("delivery:fresh-1", self.native.messages)
        self.assertEqual([p["parent_id"] for _, p in self.square.written], [100])
        self.assertEqual(self.store.get("outbox:cursor")["offset"], self.path.stat().st_size)

    def test_pass_is_bounded_by_bytes_and_resumes_from_the_cursor(self):
        import custos_observe
        self.write_log()
        with mock.patch.object(custos_observe, "DRAIN_MAX_BYTES", 20000):
            cursor = {"path": str(self.path), "offset": 0}
            self.observer._drain_outbox(self.path, cursor)
            self.assertNotIn("delivery:fresh-1", self.native.messages)
            first = self.store.get("outbox:cursor")["offset"]
            self.assertLess(first, self.path.stat().st_size)
        self.observer._drain_outbox(self.path, dict(self.store.get("outbox:cursor")))
        self.assertIn("delivery:fresh-1", self.native.messages)
        self.assertEqual(self.store.get("outbox:cursor")["offset"], self.path.stat().st_size)

class OutboxOversizedLineTests(OutboxDrainTests):
    """A trajectory line longer than the reader's cap is a reasoning or output
    step, never a square message. It is stepped over, once, out loud; a line still
    being written (no newline yet) is left for the next pass. On 2026-09-12 a
    216 KB Qwen thought froze the cursor for eleven hours with 19 replies behind it
    while square_queue, breaking on the same line, reported zero."""

    def write_log_with_big_line(self):
        lines = [cm.encode({"type": "trajectory", "step_id": "header"})]
        lines.append(cm.encode({"type": "reasoning", "step_id": "big-1", "thought": "L" * (200 * 1024)}))
        lines.append(cm.encode({"type": "message", "step_id": "fresh-1", "from": "custos", "to": "square:peer:10:100",
                                "content": "a fresh reply", "ts": self.stamp(3600)}))
        self.path.write_text("\n".join(lines) + "\n")

    def test_drain_steps_over_an_oversized_line_and_square_queue_sees_past_it(self):
        from custos_square import square_queue, read_native_line
        self.write_log_with_big_line()
        self.store.put("outbox:cursor", {"path": str(self.path), "offset": 0})
        self.assertEqual([q["step_id"] for q in square_queue(self.store, self.path)], ["fresh-1"])
        cursor = {"path": str(self.path), "offset": 0}
        self.observer._drain_outbox(self.path, cursor)
        self.assertIn("delivery:fresh-1", self.native.messages)
        header_len = len(cm.encode({"type": "trajectory", "step_id": "header"})) + 1
        self.assertIn("oversized:%d" % header_len, self.native.messages)
        self.assertIn("stepped over a", self.native.messages["oversized:%d" % header_len]["content"])
        self.assertEqual(self.store.get("outbox:cursor")["offset"], self.path.stat().st_size)
        with self.path.open("rb") as source:
            self.assertEqual(read_native_line(source)[1], "line")
            self.assertEqual(read_native_line(source), (b"", "oversized"))
            self.assertEqual(read_native_line(source)[1], "line")
            self.assertEqual(read_native_line(source), (b"", "eof"))

    def test_an_oversized_line_still_being_written_is_left_for_the_next_pass(self):
        from custos_square import read_native_line
        self.write_log_with_big_line()
        end = self.path.stat().st_size
        with self.path.open("ab") as handle:
            handle.write(cm.encode({"type": "reasoning", "step_id": "big-2", "thought": "M" * (300 * 1024)}).encode("utf-8"))  # no newline yet
        cursor = {"path": str(self.path), "offset": 0}
        self.observer._drain_outbox(self.path, cursor)
        self.assertEqual(self.store.get("outbox:cursor")["offset"], end, "the cursor waits at the start of the unfinished line")
        self.assertEqual([k for k in self.native.messages if k.startswith("oversized:")], ["oversized:%d" % (len(cm.encode({"type": "trajectory", "step_id": "header"})) + 1)])
        with self.path.open("rb") as source:
            source.seek(end)
            self.assertEqual(read_native_line(source), (b"", "partial"))
            self.assertEqual(source.tell(), end)


class GuardScopeTests(ChatFixture):
    """The cross-room rule (an unanswered group ask must not be moved into a DM
    with someone from that room) belongs to the social thinker, which exports
    CHAT_GUARD_CROSS_ROOM=1. The mind's window covers one conversation only."""

    def setUp(self):
        super().setUp()
        self.group = "signal-ggggggggggggggggggggggg1"
        self.dm = "signal-dddddddddddddddddddddddd1"
        aci = '"aci":"aci-jack-1"'
        # Jack in the group two hours ago, then our unanswered line to the group ten minutes ago.
        self.append({"type": "message", "step_id": "g-in-1", "from": self.group, "to": "custos", "source": "operator-transport",
                     "content": '{"scope":"group",' + aci + ',"speaker":"Jack"} what do you think?', "ts": now_iso(-7200)})
        self.append({"type": "message", "step_id": "g-out-1", "from": "custos", "to": self.group, "source": "chat",
                     "content": "I think it depends", "ts": now_iso(-600)})
        # Jack's DM to us, three hours ago, with a transport receipt so the reply is bridge-deliverable.
        self.append({"type": "message", "step_id": UUID_B, "from": self.dm, "to": "custos", "source": "operator-transport",
                     "request_id": "signal:dm-1", "authority": "external",
                     "content": '{"scope":"direct",' + aci + ',"speaker":"Jack"} can you send me the command?', "ts": now_iso(-10800)})
        state = self.identity / ".state" / "transport"
        state.mkdir(parents=True, exist_ok=True)
        (state / (hashlib.sha256(b"signal:dm-1").hexdigest() + ".json")).write_text(json.dumps({
            "original": {"request_id": "signal:dm-1", "sender": self.dm, "authority": "external", "source_url": "", "content": "c"},
            "step_id": UUID_B, "phase": "queued", "reply_offset": 0}))

    def test_the_mind_may_dm_across_rooms_but_the_social_thinker_may_not(self):
        # Jack spoke last in the DM, so only the cross-room rule can refuse: the social
        # thinker (CHAT_GUARD_CROSS_ROOM=1) may not move the unanswered group ask here.
        with mock.patch.dict(os.environ, {"CHAT_DOUBLE_TEXT_GUARD_HOURS": "2", "CHAT_GUARD_CROSS_ROOM": "1"}):
            refused = self.chat("reply", "--reply-to", UUID_B, self.dm, "Social nudge.")
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("Do not move the ask to a DM", refused.stderr)
        self.assertEqual([m for m in self.outgoing() if m["to"] == self.dm], [])
        # The mind, same window, no cross-room rule: the decision DM goes through.
        with mock.patch.dict(os.environ, {"CHAT_DOUBLE_TEXT_GUARD_HOURS": "2"}):
            allowed = self.chat("reply", "--reply-to", UUID_B, self.dm, "Here is the command.")
            self.assertEqual(allowed.returncode, 0, allowed.stderr)
            self.assertIn("queued for the Signal bridge", allowed.stderr)
        self.assertEqual([m["content"] for m in self.outgoing() if m["to"] == self.dm], ["Here is the command."])
        # Now the identity spoke last in the DM; a plain second message is refused by the
        # window itself, while a --follow-up delivery is exempt.
        with mock.patch.dict(os.environ, {"CHAT_DOUBLE_TEXT_GUARD_HOURS": "2"}):
            second = self.chat("reply", "--follow-up", "--reply-to", UUID_B, self.dm, "And the follow-up.")
            self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual([m["content"] for m in self.outgoing() if m["to"] == self.dm], ["Here is the command.", "And the follow-up."])


class ShellmStubFixture(unittest.TestCase):
    """The upstream llm stub (tests/test_inactivity_beacon.sh): shellm and every
    nested shellm run out of a copy of bin/ whose llm answers from numbered
    script files, so the stub stays in force at every level of nesting."""

    def setUp(self):
        import shutil, tempfile
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.work = Path(self.tempdir.name)
        self.toolbin = self.work / "toolbin"
        shutil.copytree(HEADLONG / "bin", self.toolbin)
        (self.work / "script").mkdir(); (self.work / "home").mkdir(); (self.work / "wd").mkdir()
        executable(self.toolbin / "llm", "#!/usr/bin/env bash\n"
                   "for a in \"$@\"; do [[ \"$a\" == \"--thinking\" ]] && main_loop=1; done\n"
                   "if [[ \"${main_loop:-0}\" -ne 1 ]]; then printf '{}\\n'; exit 0; fi\n"
                   "n=$(( $(cat \"$LLM_COUNT\" 2>/dev/null || echo 0) + 1 ))\n"
                   "printf '%s' \"$n\" > \"$LLM_COUNT\"\n"
                   "if [[ -f \"$LLM_SCRIPT/$n\" ]]; then cat \"$LLM_SCRIPT/$n\"; else cat \"$LLM_SCRIPT/last\"; fi\n")
        (self.work / "count").write_text("")
        self.env = dict(os.environ, PATH=str(self.toolbin) + ":" + str(HEADLONG / "tools") + ":" + os.environ["PATH"],
                        LLM_COUNT=str(self.work / "count"), LLM_SCRIPT=str(self.work / "script"), HOME=str(self.work / "home"),
                        HEADLONG_HOME=str(self.work / "home" / ".headlong"), ANTHROPIC_API_KEY="test-key", SHELLM_MODEL="test-model",
                        SHELLM_ENV="local", SHELLM_RUN_SUMMARY="0", TRAJ_DIR=str(self.work / "traj"))
        for key in ("IDENTITY_DIR", "IDENTITY_NAME", "MEM_DIR", "TRAJ_ID", "ROOT_TRAJ_ID", "SHELLM_MAX_ITERATIONS", "SHELLM_SYNC_CHILD"):
            self.env.pop(key, None)
        (self.work / "traj").mkdir()

    def fence(self, name, body):
        (self.work / "script" / name).write_text("```bash\n" + body + "\n```\n")

    def run_shellm(self, *args, timeout=240):
        return subprocess.run([str(self.toolbin / "shellm"), "--workdir", str(self.work / "wd"), *args],
                              cwd=str(self.work / "wd"), env=self.env, text=True, capture_output=True, timeout=timeout, stdin=subprocess.DEVNULL)

    def steps(self):
        found = []
        for tj in self.work.rglob("trajectory.jsonl"):
            with tj.open() as handle:
                for line in handle:
                    try:
                        found.append((tj, json.loads(line)))
                    except ValueError:
                        continue
        return found


class SynchronousHelperTests(ShellmStubFixture):
    def test_wait_child_merge_is_stamped_sync_and_the_parent_reads_the_report(self):
        self.fence("1", 'subrun --wait --max-iterations 2 "sub task" > sub.txt 2>&1; echo "sub done"; cat sub.txt')
        self.fence("2", "FINAL=sub-answer")
        self.fence("last", "FINAL=done")
        result = self.run_shellm("--max-iterations", "3", "parent task")
        merges = [s for _, s in self.steps() if s.get("type") == "merge"]
        self.assertEqual(len(merges), 1, result.stderr[-2000:])
        self.assertIs(merges[0].get("sync"), True, merges[0])
        self.assertIn("sub-answer", merges[0].get("content", ""))
        self.assertIn("sub done", result.stderr + result.stdout + "".join(s.get("stdout", "") for _, s in self.steps() if s.get("type") == "shell-output"))

    def test_last_iteration_is_announced_as_feedback_before_the_final_call(self):
        self.fence("1", "echo first")
        self.fence("last", "FINAL=done")
        result = self.run_shellm("--max-iterations", "2", "bounded task")
        self.assertEqual(result.returncode, 0, result.stderr[-2000:])
        kinds = [(s.get("type"), s.get("content", "")[:40]) for _, s in self.steps()]
        feedback = [s for _, s in self.steps() if s.get("type") == "feedback"]
        self.assertEqual(len(feedback), 1, kinds)
        self.assertIn("LAST iteration (2/2)", feedback[0]["content"])
        types = [s.get("type") for _, s in self.steps()]
        self.assertLess(types.index("feedback"), len(types) - types[::-1].index("reasoning") - 1, "the notice lands before the final reasoning step")


class SubrunModeEnvTests(unittest.TestCase):
    def test_wait_mode_marks_the_child_synchronous_and_detach_mode_does_not(self):
        import tempfile, time as _time
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); fake_bin = base / "bin"; fake_bin.mkdir()
            executable(fake_bin / "shellm", "#!/usr/bin/env bash\nprintf 'sync=%s\\n' \"${SHELLM_SYNC_CHILD:-unset}\"\nprintf 'FINAL: fake child complete\\n'\n")
            env = dict(os.environ, PATH=str(fake_bin) + ":" + str(HEADLONG / "bin") + ":" + os.environ["PATH"], TMPDIR=str(base))
            env.pop("IDENTITY_DIR", None)
            waited = subprocess.run(["subrun", "--wait", "--cwd", str(base), "--max-iterations", "2", "--report", str(base / "wait.report"), "task"],
                                    env=env, text=True, capture_output=True, timeout=60)
            self.assertEqual(waited.returncode, 0, waited.stderr)
            self.assertIn("sync=1", (base / "wait.report").read_text())
            detached = subprocess.run(["subrun", "--detach", "--cwd", str(base), "--max-iterations", "2", "--report", str(base / "detach.report"), "task"],
                                      env=env, text=True, capture_output=True, timeout=60)
            self.assertEqual(detached.returncode, 0, detached.stderr)
            for _ in range(50):
                if "state: exited" in (base / "detach.report").read_text():
                    break
                _time.sleep(0.2)
            self.assertIn("sync=unset", (base / "detach.report").read_text())


if __name__ == "__main__":
    unittest.main()
