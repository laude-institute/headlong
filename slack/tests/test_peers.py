"""Peer hearing: another Headlong persona's bot posts reach the mind, bounded.

Two personas in one thread each answer every message the other posts, so
the gate that lets a peer through comes with a loop guard: a run limit per
thread that a person's message resets, and an hourly cap. Everything else
about a peer message (mention gate, active threads, naming) is the same as
for a person.
"""

from __future__ import annotations

import logging
import threading
import time

import pytest

from headlong_slack import config as config_mod
from headlong_slack.config import Config
from headlong_slack.inbound import Inbound
from headlong_slack.state import ActiveThreads, PeerGuard

BOT = "U_BOT"
PEER = "U_PEER"
OTHER_BOT = "U_OTHERBOT"
NICK = "U_NICK"
CHAN = "C_CHAN"
PARENT = "111.222"


# -- config ----------------------------------------------------------------


def test_peer_bot_users_parsed_and_junk_ignored(monkeypatch):
    monkeypatch.setenv("SLACK_PEER_BOT_USERS", " U0C2G1517EC, B0C15LE90KH;harris ,U0BN5FSURBN,,u0lower")
    assert config_mod._peer_bot_users() == frozenset({"U0C2G1517EC", "U0BN5FSURBN"})


def test_peer_bot_users_default_empty(monkeypatch):
    monkeypatch.delenv("SLACK_PEER_BOT_USERS", raising=False)
    assert config_mod._peer_bot_users() == frozenset()


def test_int_env_defaults_and_clamps(monkeypatch):
    monkeypatch.delenv("SLACK_PEER_MAX_TURNS", raising=False)
    assert config_mod._int_env("SLACK_PEER_MAX_TURNS", 4, 0, 50) == 4
    monkeypatch.setenv("SLACK_PEER_MAX_TURNS", "999")
    assert config_mod._int_env("SLACK_PEER_MAX_TURNS", 4, 0, 50) == 50
    monkeypatch.setenv("SLACK_PEER_MAX_TURNS", "nope")
    assert config_mod._int_env("SLACK_PEER_MAX_TURNS", 4, 0, 50) == 4


# -- guard -----------------------------------------------------------------


def test_guard_allows_max_turns_then_blocks_until_a_person_speaks():
    g = PeerGuard(max_turns=2, hourly_cap=100)
    assert g.allow(CHAN, PARENT) == (True, "")
    assert g.allow(CHAN, PARENT) == (True, "")
    blocked, reason = g.allow(CHAN, PARENT)
    assert blocked is False and "2 peer messages in a row" in reason
    # Repeat refusals are silent so the caller logs once per thread.
    assert g.allow(CHAN, PARENT) == (False, "")
    # Another thread is unaffected.
    assert g.allow(CHAN, "222.333") == (True, "")
    g.human_spoke(CHAN, PARENT)
    ok, reason = g.allow(CHAN, PARENT)
    assert ok is True
    # After the reset the next refusal is reported again.
    g.allow(CHAN, PARENT)
    assert "in a row" in g.allow(CHAN, PARENT)[1]


def test_guard_hourly_cap_across_threads(monkeypatch):
    g = PeerGuard(max_turns=100, hourly_cap=3)
    now = [1_000_000.0]
    monkeypatch.setattr("headlong_slack.state.time.time", lambda: now[0])
    assert g.allow(CHAN, "1")[0] and g.allow(CHAN, "2")[0] and g.allow(CHAN, "3")[0]
    blocked, reason = g.allow(CHAN, "4")
    assert blocked is False and "hourly cap of 3" in reason
    now[0] += 3601
    assert g.allow(CHAN, "4")[0] is True


def test_guard_zero_turns_blocks_every_peer():
    g = PeerGuard(max_turns=0, hourly_cap=100)
    assert g.allow(CHAN, PARENT)[0] is False


# -- inbound ---------------------------------------------------------------


class _Client:
    def __init__(self):
        self.lock = threading.Lock()

    def users_info(self, user):
        names = {NICK: "Nick Jalbert", PEER: "harris", OTHER_BOT: "otherbot"}
        return {"user": {"profile": {"display_name": names.get(user, user)}}}

    def chat_getPermalink(self, *, channel, message_ts):
        return {"permalink": f"https://slack.test/{channel}/p{message_ts}"}

    def conversations_info(self, channel):
        return {"channel": {"name": "headlong-bot-chatter", "is_im": False}}

    def chat_postMessage(self, **kwargs):
        raise AssertionError(f"unexpected chat_postMessage {kwargs}")

    def conversations_replies(self, **_kw):
        return {"ok": True, "messages": []}


class _App:
    def __init__(self, client):
        self.client = client

    def event(self, _name):
        def deco(fn):
            return fn
        return deco


class _Posted:
    def __init__(self):
        self.items = []

    def __call__(self, url, json=None, timeout=None):
        self.items.append(json)

        class _R:
            def raise_for_status(self_inner):
                return None

        return _R()


@pytest.fixture
def posted(monkeypatch):
    p = _Posted()
    monkeypatch.setattr("headlong_slack.inbound.httpx.post", p)
    return p


def _cfg(tmp_path, *, peers=frozenset({PEER}), max_turns=4, hourly_cap=30):
    serve = tmp_path / "serve"
    ident = serve / "audel"
    ident.mkdir(parents=True, exist_ok=True)
    state = tmp_path / "state"
    state.mkdir(exist_ok=True)
    return Config(
        serve_root=serve,
        identity="audel",
        identity_dir=ident,
        bot_token="xoxb-test",
        app_token="xapp-test",
        web_url="http://127.0.0.1:9",
        state_dir=state,
        thread_followups=True,
        thread_join_backfill=0,
        peer_bot_users=frozenset(peers),
        peer_max_turns=max_turns,
        peer_hourly_cap=hourly_cap,
    )


_ts = [200.0]


def _event(*, user, text, bot=False, thread_ts=PARENT, mention=True, event_type=None):
    _ts[0] += 1
    event = {
        "type": event_type or ("app_mention" if mention else "message"),
        "user": user,
        "text": (f"<@{BOT}> " if mention else "") + text,
        "channel": CHAN,
        "ts": f"{_ts[0]:.3f}",
        "channel_type": "channel",
    }
    if thread_ts is not None:
        event["thread_ts"] = thread_ts
    if bot:
        event["bot_id"] = "B_" + user
    return event


class _Bridge:
    """One Inbound kept alive across several events."""

    def __init__(self, tmp_path, posted, **cfg_kw):
        self.cfg = _cfg(tmp_path, **cfg_kw)
        self.threads = ActiveThreads(self.cfg.state_dir / "threads.json")
        self.ib = Inbound(self.cfg, _App(_Client()), BOT, self.threads)
        self.posted = posted
        self.logger = logging.getLogger("test-peers")

    def send(self, event, expect_delivery: bool):
        before = len(self.posted.items)
        self.ib._on_event(event, self.logger)
        deadline = time.time() + (2 if expect_delivery else 0.3)
        while time.time() < deadline and len(self.posted.items) == before:
            time.sleep(0.02)
        time.sleep(0.05)
        delivered = len(self.posted.items) - before
        assert delivered == (1 if expect_delivery else 0), (
            f"expected {'a' if expect_delivery else 'no'} delivery for {event['user']}, "
            f"got {delivered}"
        )
        return self.posted.items[-1] if delivered else None

    def deliver(self, event, count: int):
        """Send one event and wait for exactly `count` deliveries."""
        before = len(self.posted.items)
        self.ib._on_event(event, self.logger)
        deadline = time.time() + 2
        while time.time() < deadline and len(self.posted.items) - before < count:
            time.sleep(0.02)
        time.sleep(0.05)
        got = len(self.posted.items) - before
        assert got == count, f"expected {count} deliveries, got {got}"
        return self.posted.items[before:]

    def close(self):
        self.ib.stop()
        self.ib._worker.join(timeout=1)


@pytest.fixture
def bridge(tmp_path, posted):
    made = []

    def make(**kw):
        b = _Bridge(tmp_path, posted, **kw)
        made.append(b)
        return b

    yield make
    for b in made:
        b.close()


def test_peer_mention_is_forwarded_and_named_as_a_persona(bridge):
    b = bridge()
    body = b.send(_event(user=PEER, text="hello audel", bot=True), True)
    assert body["from_name"] == f"slack-{PEER}-{CHAN}-{PARENT}"
    assert body["content"].startswith(
        "(Slack: harris, a Headlong persona like you, not a person in #headlong-bot-chatter"
    )
    assert body["content"].endswith("hello audel")
    assert body["source_url"].startswith("https://slack.test/")
    # The thread is now active, like after a person's mention.
    assert b.threads.is_active(CHAN, PARENT)


def test_unlisted_bot_still_dropped(bridge):
    b = bridge()
    b.send(_event(user=OTHER_BOT, text="hi", bot=True), False)


def test_no_peers_configured_keeps_old_rule(bridge):
    b = bridge(peers=frozenset())
    b.send(_event(user=PEER, text="hi", bot=True), False)


def test_peer_without_mention_in_inactive_thread_dropped(bridge):
    b = bridge()
    b.send(_event(user=PEER, text="just chatting", bot=True, mention=False), False)


def test_peer_followup_in_active_thread_forwarded(bridge):
    b = bridge()
    b.threads.touch(CHAN, PARENT)
    b.send(_event(user=PEER, text="following up", bot=True, mention=False), True)


def test_loop_guard_stops_peer_after_max_turns_and_person_resets(bridge):
    b = bridge(max_turns=2)
    b.send(_event(user=PEER, text="one", bot=True), True)
    b.send(_event(user=PEER, text="two", bot=True), True)
    # Blocked at the cap: held, not dropped.
    b.send(_event(user=PEER, text="three", bot=True), False)
    b.send(_event(user=PEER, text="four", bot=True), False)
    # A person speaking in the thread, even without mentioning us, resets,
    # and the held messages flow first, oldest first, inside the fresh
    # allowance: two held peer messages plus the person's own.
    bodies = b.deliver(_event(user=NICK, text="carry on you two", mention=False), 3)
    assert bodies[0]["content"].endswith("three")
    assert bodies[1]["content"].endswith("four")
    assert bodies[2]["content"].endswith("carry on you two")
    # The held pair spent the fresh allowance, so a new peer message is
    # held until the next person speaks, then flows with it.
    b.send(_event(user=PEER, text="five", bot=True), False)
    bodies = b.deliver(_event(user=NICK, text="and again", mention=False), 2)
    assert bodies[0]["content"].endswith("five")
    assert bodies[1]["content"].endswith("and again")


def test_person_in_unrelated_thread_does_not_reset(bridge):
    b = bridge(max_turns=1)
    b.send(_event(user=PEER, text="one", bot=True), True)
    b.send(_event(user=PEER, text="two", bot=True), False)
    b.send(_event(user=NICK, text="elsewhere", thread_ts="555.666"), True)
    b.send(_event(user=PEER, text="three", bot=True), False)


def test_person_messages_never_guarded(bridge):
    b = bridge(max_turns=0, hourly_cap=0)
    b.send(_event(user=NICK, text="hi audel"), True)
    b.send(_event(user=NICK, text="still here"), True)


# -- the cap pauses, it does not delete -------------------------------------


def test_held_peer_message_flows_when_a_person_speaks(bridge):
    b = bridge(max_turns=1)
    b.send(_event(user=PEER, text="one", bot=True), True)
    # Blocked at the cap: held, not dropped.
    b.send(_event(user=PEER, text="two", bot=True), False)
    # The person's followup releases the held message ahead of itself,
    # oldest first: it was posted before the person spoke.
    bodies = b.deliver(_event(user=NICK, text="carry on", mention=False), 2)
    assert bodies[0]["content"].endswith("two")
    assert bodies[1]["content"].endswith("carry on")


def test_person_in_another_thread_does_not_release_a_hold(bridge):
    b = bridge(max_turns=1)
    b.send(_event(user=PEER, text="one", bot=True), True)
    b.send(_event(user=PEER, text="two", bot=True), False)
    # A person in an unrelated thread does not touch our hold.
    b.send(_event(user=NICK, text="elsewhere", thread_ts="555.666"), True)
    b.send(_event(user=PEER, text="three", bot=True), False)
    bodies = b.deliver(_event(user=NICK, text="back here", mention=False), 2)
    assert bodies[0]["content"].endswith("two")
    assert bodies[1]["content"].endswith("back here")


def test_hourly_cap_refusal_is_held_and_flows_after_the_hour(monkeypatch):
    # Guard-level, like the hourly-cap test above: the bridge fixture's
    # wait loops read the same patched clock, so freezing time with a
    # live bridge would spin forever.
    now = [1_000_000.0]
    monkeypatch.setattr("headlong_slack.state.time.time", lambda: now[0])
    g = PeerGuard(max_turns=10, hourly_cap=2)
    assert g.allow(CHAN, "1")[0]
    assert g.allow(CHAN, "2")[0]
    g.hold(CHAN, PARENT, "late")
    # A person speaking inside the same hour cannot release it: the
    # hourly cap still refuses, so the message stays paused.
    assert g.human_spoke(CHAN, PARENT) == []
    now[0] += 3601
    assert g.human_spoke(CHAN, PARENT) == ["late"]


def test_hold_is_bounded_and_keeps_the_oldest_first():
    g = PeerGuard(max_turns=4, hourly_cap=100)
    for _ in range(4):
        assert g.allow(CHAN, PARENT)[0]
    payloads = [f"p{i}" for i in range(10)]
    for p in payloads:
        g.hold(CHAN, PARENT, p)
    # Overflow dropped the newest, so the oldest eight are kept, and each
    # person speech releases at most the fresh allowance of them.
    assert g.human_spoke(CHAN, PARENT) == payloads[:4]
    assert g.human_spoke(CHAN, PARENT) == payloads[4:8]
    assert g.human_spoke(CHAN, PARENT) == []
