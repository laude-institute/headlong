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
    b.send(_event(user=PEER, text="three", bot=True), False)
    b.send(_event(user=PEER, text="four", bot=True), False)
    # A person speaking in the thread, even without mentioning us, resets.
    b.send(_event(user=NICK, text="carry on you two", mention=False), True)
    b.send(_event(user=PEER, text="five", bot=True), True)


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


# -- un-mentioned gate drops are named (2026-11-10 finding) -----------------
#
# The mention/active-thread gate is the bridge's one silent filter besides
# the PeerGuard caps: a channel post with no mention and no watched thread
# is dropped before the mind ever sees it, with no log line anywhere, so
# the author reads the post as delivered while the mind reads silence.
# Measured on a live pair of these bridges: 75 of 127 peer posts in five
# weeks dropped here dark, 8 more by the caps (which log each block once).
# Every drop now names itself.


def test_unmentioned_channel_post_logs_the_drop(bridge, caplog):
    peer_post = _event(user=PEER, text="peer chatter", bot=True, mention=False)
    reply_post = _event(user=NICK, text="reply chatter", mention=False)
    top_post = _event(user=NICK, text="top-level chatter", mention=False, thread_ts=None)
    b = bridge()
    with caplog.at_level(logging.INFO, logger="test-peers"):
        b.send(peer_post, False)
        b.send(reply_post, False)
        b.send(top_post, False)
    drops = [r for r in caplog.records if "not forwarded" in r.getMessage()]
    assert len(drops) == 3, [r.getMessage() for r in caplog.records]
    assert any(
        r.levelno == logging.WARNING
        and r.getMessage() == (
            f"peer {PEER} in {CHAN}/{PARENT} "
            "not forwarded: no mention and no active thread"
        )
        for r in drops
    ), [r.getMessage() for r in drops]
    person_drops = [
        r
        for r in drops
        if r.levelno == logging.INFO
        and r.getMessage().startswith(f"person {NICK} in {CHAN}/")
        and r.getMessage().endswith("not forwarded: no mention and no active thread")
    ]
    assert len(person_drops) == 2, [r.getMessage() for r in caplog.records]
    # A top-level post has no thread, so the drop line anchors at its own ts.
    assert any(
        f"person {NICK} in {CHAN}/{top_post['ts']} " in r.getMessage()
        for r in person_drops
    ), [r.getMessage() for r in caplog.records]


def test_mentioned_and_followup_posts_log_no_drop(bridge, caplog):
    b = bridge()
    with caplog.at_level(logging.INFO, logger="test-peers"):
        b.send(_event(user=NICK, text="hello"), True)
        b.send(_event(user=NICK, text="still here", mention=False), True)
    assert not [r for r in caplog.records if "not forwarded" in r.getMessage()]
