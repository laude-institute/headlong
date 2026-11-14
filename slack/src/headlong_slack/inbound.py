"""Slack events -> mind log.

Handlers return immediately (bolt acks the envelope); a worker thread
drains an internal queue and POSTs each message to the local shellm web
API, which appends it to the identity's trajectory via `bin/chat`.
"""

from __future__ import annotations

import concurrent.futures
import logging
import queue
import threading
import time
from dataclasses import dataclass
from typing import Any

import httpx
from slack_bolt import App

from . import naming
from .config import Config
from .slackfmt import clean_inbound
from .state import ActiveThreads, Deduper, PeerGuard

log = logging.getLogger(__name__)

DELIVERY_ATTEMPTS = 3
DELIVERY_ERROR_TEXT = (
    "(bridge error: I couldn't reach my mind just now — please try again in a bit)"
)


def _refusal_reason(response: httpx.Response) -> str:
    """The one-line reason behind a 409 from the web API, for the log."""
    try:
        detail = response.json().get("detail")
    except Exception:
        return response.text[:200]
    if isinstance(detail, dict):
        return str(detail.get("message") or detail)[:200]
    return str(detail)[:200]
# Bound reaction parent-lookups so a hung reactions.get cannot stall
# the single inbound drain thread. Fail open rather than wait.
ITEM_LOOKUP_TIMEOUT = 2
# Same bound for first-join conversations.replies. Fail open: deliver
# the mention without prior lines rather than stall later messages.
JOIN_BACKFILL_TIMEOUT = 2
# Per-line cap so a single huge Slack message cannot dump the mind log.
JOIN_BACKFILL_LINE_CHARS = 200


def reaction_text(reaction: str, item_ts: str, thread_ts: str | None) -> str:
    """Body for a reaction inbound.

    Routing uses the parent thread so a reply lands in the right Slack
    thread. When the reacted-to message is a reply inside that thread,
    keep `item_ts` in the body so the mind log still names the line.
    """
    body = f":{reaction}:"
    if thread_ts and item_ts != thread_ts:
        body = f"{body} (on {item_ts})"
    return body


@dataclass
class InboundMessage:
    from_name: str
    user: str
    channel: str
    thread_ts: str | None  # where an error notice would go; None = top level
    message_ts: str
    text: str
    # True for channel reactions: resolve parent thread_ts in the worker
    # so the bolt handler never blocks on reactions.get.
    resolve_parent: bool = False
    # Reactions skip chat_getPermalink on the drain thread. The Slack
    # client's default timeout is 30s; a burst of reaction permalink
    # lookups would otherwise stall later human messages.
    is_reaction: bool = False
    # First @mention in a thread: drain worker prepends capped prior lines.
    # Bolt must not wait on conversations.replies.
    backfill: bool = False
    # Posted by another Headlong persona's bot (config.peer_bot_users).
    is_peer: bool = False


class SlackNames:
    """Cached display names for the '(Slack: Dana Kim in #eng)' header."""

    def __init__(self, client: Any):
        self._client = client
        self._users: dict[str, str] = {}
        self._channels: dict[str, str] = {}

    def user(self, user_id: str) -> str:
        if user_id not in self._users:
            name = user_id
            try:
                profile = self._client.users_info(user=user_id)["user"]
                name = (
                    profile.get("profile", {}).get("display_name")
                    or profile.get("real_name")
                    or user_id
                )
            except Exception:
                log.warning("users_info failed for %s", user_id, exc_info=True)
            self._users[user_id] = name
        return self._users[user_id]

    def place(self, channel_id: str) -> str:
        if channel_id.startswith("D"):
            return "DM"
        if channel_id not in self._channels:
            name = channel_id
            try:
                info = self._client.conversations_info(channel=channel_id)["channel"]
                name = "#" + info.get("name", channel_id)
            except Exception:
                log.warning("conversations_info failed for %s", channel_id, exc_info=True)
            self._channels[channel_id] = name
        return self._channels[channel_id]


def reaction_to_inbound(
    event: dict[str, Any], *, bot_user_id: str
) -> tuple[str, str, str, str, bool] | None:
    """Decide whether a reaction_added event should reach the mind log.

    Returns (user, channel, item_ts, reaction, want_thread) or None to drop.
    want_thread is True for channels (lookup parent thread_ts); False for DMs.
    """
    if event.get("bot_id"):
        return None
    user = event.get("user")
    if not user or user == bot_user_id:
        return None
    reaction = event.get("reaction")
    if not reaction:
        return None
    item = event.get("item") or {}
    if item.get("type") != "message":
        return None
    channel = item.get("channel")
    item_ts = item.get("ts")
    if not channel or not item_ts:
        return None
    is_im = channel.startswith("D")
    item_user = event.get("item_user")
    # DMs: every reaction is for us. Channels: only reactions on our messages.
    if not is_im and item_user != bot_user_id:
        return None
    return (user, channel, item_ts, reaction, not is_im)


class Inbound:
    def __init__(
        self,
        cfg: Config,
        app: App,
        bot_user_id: str,
        threads: ActiveThreads,
    ):
        self.cfg = cfg
        self.app = app
        self.bot_user_id = bot_user_id
        self.bot_mention = f"<@{bot_user_id}>"
        self.threads = threads
        self.names = SlackNames(app.client)
        self.dedupe = Deduper()
        self.peers = PeerGuard(cfg.peer_max_turns, cfg.peer_hourly_cap)
        self.queue: queue.Queue[InboundMessage | None] = queue.Queue()
        self._chat_url = (
            f"{cfg.web_url}/api/identities/{cfg.identity_api_id}/chat"
        )
        app.event("app_mention")(self._on_event)
        app.event("message")(self._on_event)
        app.event("reaction_added")(self._on_reaction)
        # One lookup worker for the process, not one executor per reaction.
        # shutdown(wait=False) cannot kill a hung Slack SDK call; a shared
        # pool is what bounds live threads when lookups time out.
        self._lookup_pool = concurrent.futures.ThreadPoolExecutor(
            max_workers=1, thread_name_prefix="slack-item-lookup"
        )
        # At most one Slack lookup in flight (reactions.get or
        # conversations.replies). Timed-out work uses the fallback
        # immediately instead of queueing another stale call.
        self._lookup_lock = threading.Lock()
        self._lookup_future: concurrent.futures.Future[Any] | None = None
        self._worker = threading.Thread(
            target=self._drain, name="slack-inbound", daemon=True
        )
        self._worker.start()

    # -- event intake (bolt handler thread; must return fast) ----------------

    def _on_reaction(self, event: dict[str, Any], logger: logging.Logger) -> None:
        """Land emoji reactions on our messages (and all DM reactions) in the mind log.

        Channel reactions on other people's messages are dropped — same gate as
        un-mentioned channel traffic. Body is `:name:`, plus `(on <item_ts>)`
        when the reacted-to line is a reply inside a thread.

        Thread parent lookup happens in the delivery worker, not here: bolt
        must ack the envelope without waiting on the Web API.
        """
        msg = reaction_to_inbound(event, bot_user_id=self.bot_user_id)
        if msg is None:
            return
        user, channel, item_ts, reaction, want_thread = msg
        event_ts = event.get("event_ts") or ""
        if not self.dedupe.add(f"reaction:{channel}:{item_ts}:{user}:{reaction}:{event_ts}"):
            return
        if want_thread:
            thread_ts = item_ts
            from_name = naming.encode(user, channel, thread_ts)
        else:
            thread_ts = None
            from_name = naming.encode(user, channel)
        self.queue.put(
            InboundMessage(
                from_name,
                user,
                channel,
                thread_ts,
                item_ts,
                f":{reaction}:",
                resolve_parent=want_thread,
                is_reaction=True,
            )
        )

    def _item_thread_ts(self, channel: str, ts: str) -> str | None:
        """Parent thread_ts for the reacted-to message, if it is in a thread.

        conversations.history only returns parent-channel messages, so a
        reaction on a reply looks up empty there. conversations.replies is
        keyed by the thread parent, not the item. reactions.get returns the
        item itself (including thread_ts) for both roots and replies.

        Bound to ITEM_LOOKUP_TIMEOUT so a hung Web API call cannot stall
        the single drain thread. Fail open to None so the caller uses
        item_ts as the thread root.
        """
        found = self._lookup_item_message(channel, ts)
        if not found:
            return None
        return found.get("thread_ts") or None

    def _try_lookup(self, fn: Any, *, timeout: float, what: str, channel: str, ts: str) -> Any | None:
        """Run fn on the shared lookup worker. At most one call in flight.

        If a previous call is still running after a timeout, do not queue
        another stale lookup — return None immediately so the drain thread
        can take the next item. Fail open on timeout or Slack error.
        """
        with self._lookup_lock:
            fut = self._lookup_future
            if fut is not None and not fut.done():
                return None
            fut = self._lookup_pool.submit(fn)
            self._lookup_future = fut
        try:
            return fut.result(timeout=timeout)
        except Exception:
            log.warning("%s failed for %s ts=%s", what, channel, ts, exc_info=True)
            return None

    def _lookup_item_message(self, channel: str, ts: str) -> dict[str, Any] | None:
        def _call() -> dict[str, Any] | None:
            resp = self.app.client.reactions_get(channel=channel, timestamp=ts)
            msg = resp.get("message") or {}
            return msg or None

        found = self._try_lookup(
            _call,
            timeout=ITEM_LOOKUP_TIMEOUT,
            what="reactions.get",
            channel=channel,
            ts=ts,
        )
        return found or None

    def _on_event(self, event: dict[str, Any], logger: logging.Logger) -> None:
        user = event.get("user")
        # Bot posts are dropped, except from a listed peer persona. Peers
        # then pass the same mention / active-thread gate as people, plus
        # the loop guard below. Legacy bot_message posts carry no user id
        # and never qualify.
        is_peer = bool(event.get("bot_id")) and bool(user) and user in self.cfg.peer_bot_users
        if (event.get("bot_id") and not is_peer) or event.get("subtype"):
            return
        text = event.get("text") or ""
        if not user or user == self.bot_user_id:
            return
        channel = event.get("channel")
        ts = event.get("ts")
        if not channel or not ts:
            return
        if not self.dedupe.add(f"{channel}:{ts}"):
            return

        first_join = False
        if event.get("channel_type") == "im":
            # DMs: everything is for us; replies go top-level.
            from_name = naming.encode(user, channel)
            thread_ts = None
        else:
            if not is_peer:
                # Any person speaking in a thread lets the peers take turns
                # again, whether or not this message is for us.
                self.peers.human_spoke(channel, event.get("thread_ts") or ts)
            mentioned = event.get("type") == "app_mention" or self.bot_mention in text
            if mentioned:
                # Anchor the conversation at the existing thread, or start
                # one at the mention itself.
                thread_ts = event.get("thread_ts") or ts
            elif self.cfg.thread_followups and self.threads.is_active(
                channel, event.get("thread_ts")
            ):
                thread_ts = event["thread_ts"]
            else:
                # Un-mentioned, and no thread we are watching: the one
                # silent drop besides the PeerGuard caps. Named so a post
                # the author sees as delivered is distinguishable from
                # quiet in the bridge log. Measured on a live pair of
                # these bridges: 75 of 127 peer posts in five weeks were
                # dropped here dark (2026-11-10 sweep).
                logger.log(
                    logging.WARNING if is_peer else logging.INFO,
                    "%s %s in %s/%s not forwarded: no mention and no active thread",
                    "peer" if is_peer else "person",
                    user, channel, event.get("thread_ts") or ts,
                )
                return
            if is_peer:
                ok, reason = self.peers.allow(channel, thread_ts)
                if not ok:
                    if reason:
                        logger.warning(
                            "peer %s in %s/%s not forwarded: %s",
                            user, channel, thread_ts, reason,
                        )
                    return
            from_name = naming.encode(user, channel, thread_ts)
            # First @mention in an existing thread: fetch prior lines on
            # the drain worker. Already-active threads have been fed
            # followups; a top-level mention has no thread above it.
            first_join = bool(
                mentioned
                and event.get("thread_ts")
                and not self.threads.is_active(channel, thread_ts)
                and self.cfg.thread_join_backfill > 0
            )
            self.threads.touch(channel, thread_ts)

        self.queue.put(
            InboundMessage(
                from_name, user, channel, thread_ts, ts, text,
                backfill=first_join, is_peer=is_peer,
            )
        )

    # -- delivery worker -----------------------------------------------------

    def _drain(self) -> None:
        while True:
            msg = self.queue.get()
            if msg is None:
                return
            try:
                self._deliver(msg)
            except Exception:
                log.exception("failed delivering %s", msg.from_name)

    def _thread_lines_before(
        self, channel: str, thread_ts: str, before_ts: str, limit: int
    ) -> list[dict[str, Any]]:
        """Prior messages in a thread, closest to before_ts, capped at limit.

        conversations.replies pages oldest-first, so one `limit`-sized
        request would return the parent and earliest replies. Cursor-walk
        to the last page (bounded by JOIN_BACKFILL_TIMEOUT and a page
        cap); keep ts < before_ts and take the tail. Fail open to [] so
        the mention still lands. Shares the one-in-flight lookup worker.
        """
        fetch = min(200, max(limit + 1, 1))
        # Enough pages for a long thread at this fetch size; the submit
        # timeout is the real bound. Stop short of the end: return []
        # rather than the oldest page.
        max_pages = 50

        def _call() -> list[dict[str, Any]]:
            collected: list[dict[str, Any]] = []
            cursor = ""
            exhausted = False
            for _ in range(max_pages):
                kwargs: dict[str, Any] = {
                    "channel": channel,
                    "ts": thread_ts,
                    "latest": before_ts,
                    "inclusive": False,
                    "limit": fetch,
                }
                if cursor:
                    kwargs["cursor"] = cursor
                resp = self.app.client.conversations_replies(**kwargs)
                batch = list(resp.get("messages") or [])
                collected.extend(batch)
                cursor = (resp.get("response_metadata") or {}).get("next_cursor") or ""
                if not cursor or not batch:
                    exhausted = True
                    break
            return collected if exhausted else []

        msgs = self._try_lookup(
            _call,
            timeout=JOIN_BACKFILL_TIMEOUT,
            what="conversations.replies",
            channel=channel,
            ts=thread_ts,
        )
        if not msgs:
            return []

        def _key(ts: str) -> float:
            try:
                return float(ts)
            except (TypeError, ValueError):
                return 0.0

        cutoff = _key(before_ts)
        out = []
        for m in msgs:
            ts = m.get("ts") or ""
            if not ts or _key(ts) >= cutoff:
                continue
            if m.get("subtype"):
                continue
            out.append(m)
        out.sort(key=lambda m: _key(m.get("ts") or ""))
        return out[-limit:]

    def _format_backfill(self, messages: list[dict[str, Any]]) -> str:
        lines: list[str] = []
        for m in messages:
            user = m.get("user")
            name = self.names.user(user) if user else (m.get("username") or "unknown")
            text = clean_inbound(m.get("text") or "", self.bot_user_id)
            if not text:
                continue
            text = " ".join(text.split())
            if len(text) > JOIN_BACKFILL_LINE_CHARS:
                text = text[: JOIN_BACKFILL_LINE_CHARS - 3] + "..."
            lines.append(f"{name}: {text}")
        if not lines:
            return ""
        n = len(lines)
        noun = "message" if n == 1 else "messages"
        header = f"[thread before this mention — {n} earlier {noun}]"
        return header + "\n" + "\n".join(lines)

    def _deliver(self, msg: InboundMessage) -> None:
        if msg.backfill and msg.thread_ts and msg.message_ts:
            prior = self._thread_lines_before(
                msg.channel,
                msg.thread_ts,
                msg.message_ts,
                self.cfg.thread_join_backfill,
            )
            block = self._format_backfill(prior)
            if block:
                msg = InboundMessage(
                    msg.from_name,
                    msg.user,
                    msg.channel,
                    msg.thread_ts,
                    msg.message_ts,
                    block + "\n\n" + msg.text,
                    backfill=False,
                )
        if msg.resolve_parent and msg.thread_ts:
            item_ts = msg.thread_ts
            parent = self._item_thread_ts(msg.channel, item_ts)
            thread_ts = parent or item_ts
            # Body starts as ":emoji:". Nested replies keep item_ts in the
            # body so the mind log names the line, not just the thread.
            reaction = msg.text[1:-1] if msg.text.startswith(":") and msg.text.endswith(":") else msg.text
            text = reaction_text(reaction, item_ts, thread_ts)
            if thread_ts != item_ts or text != msg.text:
                msg = InboundMessage(
                    naming.encode(msg.user, msg.channel, thread_ts),
                    msg.user,
                    msg.channel,
                    thread_ts,
                    msg.message_ts,
                    text,
                    resolve_parent=False,
                    is_reaction=True,
                )
            # A reaction is not request intent. Do not create or resurrect an
            # active thread — that would open the un-mentioned-reply gate.
        content = clean_inbound(msg.text, self.bot_user_id)
        if not content:
            return
        # A peer's bridge error is the other bridge talking, not the other
        # persona. Forwarding it made two minds answer an error string at each
        # other every seven seconds on 2026-09-21.
        if msg.is_peer and DELIVERY_ERROR_TEXT in content:
            log.info("peer bridge error text from %s not forwarded", msg.from_name)
            return
        # The reply-to name is spelled out because agent-typed replies (the
        # agentic path, unlike the mechanical fast-reply) must use the full
        # routing key, not the human display name.
        # A peer is named as what it is: the mind should know it is talking
        # to another persona, not a person, and that the exchange is bounded.
        who = self.names.user(msg.user)
        if msg.is_peer:
            who = f"{who}, a Headlong persona like you, not a person"
        header = (
            f"(Slack: {who} in {self.names.place(msg.channel)}"
            f" — reply with: chat reply {msg.from_name})"
        )
        body = {"content": f"{header} {content}", "from_name": msg.from_name}
        if not msg.is_reaction:
            try:
                permalink = self.app.client.chat_getPermalink(
                    channel=msg.channel, message_ts=msg.message_ts
                ).get("permalink")
                if permalink:
                    body["source_url"] = permalink
            except Exception:
                # Permalink lookup is best-effort: a Slack outage or missing
                # scope must never keep a human message out of the mind log.
                log.warning("chat_getPermalink failed for %s", msg.from_name, exc_info=True)
        for attempt in range(1, DELIVERY_ATTEMPTS + 1):
            try:
                response = httpx.post(self._chat_url, json=body, timeout=30)
                response.raise_for_status()
                return
            except httpx.HTTPStatusError as exc:
                if exc.response.status_code == 409:
                    # The mind's tool refused the message on purpose (a
                    # duplicate or a bad target); it will refuse it again,
                    # and "couldn't reach my mind" would be untrue.
                    log.warning(
                        "chat POST refused for %s: %s",
                        msg.from_name,
                        _refusal_reason(exc.response),
                    )
                    return
                log.warning(
                    "chat POST failed (attempt %d/%d)",
                    attempt,
                    DELIVERY_ATTEMPTS,
                    exc_info=True,
                )
                if attempt < DELIVERY_ATTEMPTS:
                    time.sleep(2 * attempt)
            except httpx.HTTPError:
                log.warning(
                    "chat POST failed (attempt %d/%d)",
                    attempt,
                    DELIVERY_ATTEMPTS,
                    exc_info=True,
                )
                if attempt < DELIVERY_ATTEMPTS:
                    time.sleep(2 * attempt)
        try:
            self.app.client.chat_postMessage(
                channel=msg.channel,
                thread_ts=msg.thread_ts,
                text=DELIVERY_ERROR_TEXT,
            )
        except Exception:
            log.exception("failed posting delivery error to slack")

    def stop(self) -> None:
        self.queue.put(None)
        self._lookup_pool.shutdown(wait=False, cancel_futures=True)
