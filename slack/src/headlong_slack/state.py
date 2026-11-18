"""Small bits of bridge state: event dedupe and the active-thread set."""

from __future__ import annotations

import json
import logging
import threading
import time
from collections import OrderedDict, deque
from pathlib import Path
from typing import Any

ACTIVE_THREAD_TTL = 7 * 24 * 3600

# The most cap-paused peer messages one thread holds. Overflow drops the
# newest, so what a person reading the thread would see first survives.
PEER_PAUSE_LIMIT = 8

log = logging.getLogger(__name__)


def _held_tag(payload: Any) -> str:
    """A log-safe tag for a held payload: its ts, never its text.

    The bridge logs identity (user, channel, ts), not message content,
    so the tag names the message and never echoes what it says.
    """
    ts = getattr(payload, "message_ts", None)
    if ts is None:
        ts = getattr(payload, "ts", None)
    if ts is None and isinstance(payload, dict):
        ts = payload.get("ts") or payload.get("message_ts")
    if ts:
        return str(ts)
    return type(payload).__name__


class Deduper:
    """Bounded set of recently seen event keys.

    A channel mention arrives as both app_mention and message.channels, and
    Socket Mode redelivers envelopes that are not acked in time.
    """

    def __init__(self, max_size: int = 5000):
        self._seen: OrderedDict[str, None] = OrderedDict()
        self._max_size = max_size
        self._lock = threading.Lock()

    def add(self, key: str) -> bool:
        """Record key; returns False if it was already seen."""
        with self._lock:
            if key in self._seen:
                return False
            self._seen[key] = None
            while len(self._seen) > self._max_size:
                self._seen.popitem(last=False)
            return True


class ActiveThreads:
    """Threads the bot participates in, so un-mentioned follow-ups reach it.

    Persisted as JSON ({"channel:thread_ts": last_touched_epoch}) so a bridge
    restart does not orphan ongoing conversations. Entries expire after
    ACTIVE_THREAD_TTL.
    """

    def __init__(self, path: Path):
        self._path = path
        self._lock = threading.Lock()
        self._threads: dict[str, float] = {}
        if path.is_file():
            try:
                data = json.loads(path.read_text())
                if isinstance(data, dict):
                    self._threads = {str(k): float(v) for k, v in data.items()}
            except (ValueError, TypeError):
                pass

    @staticmethod
    def _key(channel: str, thread_ts: str) -> str:
        return f"{channel}:{thread_ts}"

    def touch(self, channel: str, thread_ts: str | None) -> None:
        if not thread_ts:
            return
        with self._lock:
            self._prune()
            self._threads[self._key(channel, thread_ts)] = time.time()
            self._save()

    def is_active(self, channel: str, thread_ts: str | None) -> bool:
        if not thread_ts:
            return False
        with self._lock:
            self._prune()
            return self._key(channel, thread_ts) in self._threads

    def _prune(self) -> None:
        cutoff = time.time() - ACTIVE_THREAD_TTL
        stale = [k for k, v in self._threads.items() if v < cutoff]
        for k in stale:
            del self._threads[k]

    def _save(self) -> None:
        tmp = self._path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self._threads))
        tmp.replace(self._path)


class PeerGuard:
    """Bounds bot-to-bot traffic so two personas cannot talk forever.

    Two Headlong personas in one thread each answer every message the
    other posts. Without a bound that is an infinite loop billed to two
    LLM keys. Two limits, both counted on the messages this bridge
    forwards from peers:

    - per thread, at most `max_turns` peer messages in a row with no person
      speaking in the thread; a human message resets the count.
    - per hour, at most `hourly_cap` peer messages across all threads.

    A refused message is paused, held up to PEER_PAUSE_LIMIT per thread,
    and re-enters the allowance when a person next speaks in that thread;
    the bound itself never grows.

    In-memory only: a bridge restart resets the counts, and the hourly cap
    bounds what a restart loop could let through.
    """

    def __init__(self, max_turns: int, hourly_cap: int):
        self.max_turns = max_turns
        self.hourly_cap = hourly_cap
        self._runs: dict[str, int] = {}
        self._recent: deque[float] = deque()
        self._blocked: set[str] = set()
        self._held: dict[str, list[Any]] = {}
        self._lock = threading.Lock()

    @staticmethod
    def _key(channel: str, thread_ts: str | None) -> str:
        return f"{channel}:{thread_ts or ''}"

    def hold(self, channel: str, thread_ts: str | None, payload: Any) -> None:
        """Pause a cap-refused peer message for this thread.

        The cap is a pause, not a delete: the message re-enters the
        allowance the next time a person speaks in this thread. At most
        PEER_PAUSE_LIMIT messages are held per thread, the oldest first.
        """
        key = self._key(channel, thread_ts)
        dropped: list[Any] = []
        with self._lock:
            paused = self._held.setdefault(key, [])
            paused.append(payload)
            while len(paused) > PEER_PAUSE_LIMIT:
                dropped.append(paused.pop())
        for item in dropped:
            log.warning(
                "peer hold overflow for %s: dropped the newest "
                "message (%s)",
                key, _held_tag(item),
            )

    def human_spoke(self, channel: str, thread_ts: str | None) -> list[Any]:
        """A person posted in this thread: peers may take turns again.

        Returns the cap-paused messages for this thread that fit the
        fresh allowance, oldest first, each one spending a turn as if it
        had just arrived; the rest stay paused, not lost.
        """
        key = self._key(channel, thread_ts)
        with self._lock:
            self._runs.pop(key, None)
            self._blocked.discard(key)
            paused = self._held.pop(key, [])
        if not paused:
            return []
        released: list[Any] = []
        for index, payload in enumerate(paused):
            ok, _reason = self.allow(channel, thread_ts)
            if not ok:
                for later in paused[index:]:
                    self.hold(channel, thread_ts, later)
                break
            released.append(payload)
        log.info(
            "person speech released %d of %d cap-paused peer "
            "message(s) for %s",
            len(released), len(paused), key,
        )
        return released

    def allow(self, channel: str, thread_ts: str | None) -> tuple[bool, str]:
        """Record one forwarded peer message, or refuse it with a reason.

        The reason is empty when allowed, and empty on a repeat refusal
        for the same thread so the caller logs each block once.
        """
        key = self._key(channel, thread_ts)
        now = time.time()
        with self._lock:
            while self._recent and self._recent[0] < now - 3600:
                self._recent.popleft()
            reason = ""
            if len(self._recent) >= self.hourly_cap:
                reason = f"hourly cap of {self.hourly_cap} peer messages reached"
            elif self._runs.get(key, 0) >= self.max_turns:
                reason = (
                    f"{self.max_turns} peer messages in a row without a person; "
                    "waiting for someone to speak in the thread"
                )
            if reason:
                first = key not in self._blocked
                self._blocked.add(key)
                return False, (reason if first else "")
            self._runs[key] = self._runs.get(key, 0) + 1
            self._recent.append(now)
            return True, ""
