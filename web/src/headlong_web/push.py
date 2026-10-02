"""Web push: VAPID keys, a subscription store, and a mind-log watcher.

Keys and subscriptions live under <root>/.web-push (gitignored). Keys are
generated on first use and die with the box — installed apps simply
re-subscribe. Subscriptions are name-scoped ("pwa-nick"), not identity
scoped: any identity messaging that name triggers a push.
"""

import base64
import json
import logging
import threading
import time
from pathlib import Path

from headlong_web import discovery
from headlong_web.env import getenv

log = logging.getLogger("headlong-web.push")

STORE_DIR = ".web-push"
VAPID_PEM = "vapid_private.pem"
SUBSCRIPTIONS = "subscriptions.json"
# Only the phone client's namespace is subscribable; slack-* stays Slack's.
SUBSCRIBABLE_PREFIX = "pwa-"
BODY_LIMIT = 160

_lock = threading.Lock()


def _store_dir(root: Path) -> Path:
    path = root / STORE_DIR
    path.mkdir(mode=0o700, exist_ok=True)
    return path


def vapid_public_key(root: Path) -> str:
    """b64url application-server key for PushManager.subscribe; generates
    the keypair on first call."""
    from cryptography.hazmat.primitives.serialization import (
        Encoding,
        PublicFormat,
    )
    from py_vapid import Vapid

    pem_path = _store_dir(root) / VAPID_PEM
    with _lock:
        if pem_path.is_file():
            vapid = Vapid.from_file(str(pem_path))
        else:
            vapid = Vapid()
            vapid.generate_keys()
            vapid.save_key(str(pem_path))
            pem_path.chmod(0o600)
    raw = vapid.public_key.public_bytes(
        Encoding.X962, PublicFormat.UncompressedPoint
    )
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _subs_path(root: Path) -> Path:
    return _store_dir(root) / SUBSCRIPTIONS


def load_subscriptions(root: Path) -> list[dict]:
    path = _subs_path(root)
    if not path.is_file():
        return []
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return []
    return data if isinstance(data, list) else []


def _save_subscriptions(root: Path, subs: list[dict]) -> None:
    path = _subs_path(root)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(subs, indent=2))
    tmp.chmod(0o600)
    tmp.replace(path)


def add_subscription(root: Path, name: str, subscription: dict) -> int:
    """Upsert by endpoint; returns the subscription count for the name."""
    endpoint = subscription.get("endpoint", "")
    with _lock:
        subs = [
            s
            for s in load_subscriptions(root)
            if s.get("subscription", {}).get("endpoint") != endpoint
        ]
        subs.append({"name": name, "subscription": subscription})
        _save_subscriptions(root, subs)
        return sum(1 for s in subs if s.get("name") == name)


def remove_subscription(root: Path, endpoint: str) -> bool:
    with _lock:
        subs = load_subscriptions(root)
        kept = [
            s
            for s in subs
            if s.get("subscription", {}).get("endpoint") != endpoint
        ]
        if len(kept) == len(subs):
            return False
        _save_subscriptions(root, kept)
        return True


def notifications_for(step: dict, subs: list[dict]) -> list[dict]:
    """Which subscriptions a mind-log step should push to."""
    if step.get("type") != "message":
        return []
    to_name = step.get("to") or ""
    if not to_name.startswith(SUBSCRIBABLE_PREFIX) or not step.get("content"):
        return []
    return [s for s in subs if s.get("name") == to_name]


def _payload(step: dict, identity_id: str) -> str:
    content = str(step.get("content") or "")
    if len(content) > BODY_LIMIT:
        content = content[: BODY_LIMIT - 1] + "…"
    return json.dumps(
        {
            "title": step.get("from") or "shellm",
            "body": content,
            "url": f"/talk/{identity_id}",
            "tag": f"{identity_id}:{step.get('to')}",
        }
    )


class PushWatcher(threading.Thread):
    """Tails every identity's root mind log and pushes messages addressed
    to subscribed pwa-* names. Byte-offset cursors start at end-of-file so
    a restart never replays history."""

    def __init__(self, root: Path, poll_s: float = 1.0, rescan_s: float = 30.0):
        super().__init__(name="push-watcher", daemon=True)
        self.root = root
        self.poll_s = poll_s
        self.rescan_s = rescan_s
        # traj file -> (identity_id, byte offset)
        self._cursors: dict[Path, tuple[str, int]] = {}
        self._last_scan = 0.0

    def _rescan(self) -> None:
        self._last_scan = time.monotonic()
        for identity in discovery.scan_identities(self.root):
            traj_dir = discovery.find_root_traj_dir(identity)
            if traj_dir is None:
                continue
            traj = traj_dir / "trajectory.jsonl"
            if traj in self._cursors or not traj.is_file():
                continue
            self._cursors[traj] = (identity.id, traj.stat().st_size)

    def _drain(self, traj: Path) -> None:
        identity_id, offset = self._cursors[traj]
        try:
            size = traj.stat().st_size
        except OSError:
            return
        if size < offset:
            # A rebuilt or truncated trajectory must not leave the cursor
            # beyond EOF forever. As on first discovery, skip existing
            # history so the replacement log does not replay old pushes.
            self._cursors[traj] = (identity_id, size)
            return
        if size == offset:
            return
        with traj.open("rb") as fh:
            fh.seek(offset)
            chunk = fh.read()
        # Only consume complete lines; a partially-written line stays for
        # the next poll.
        end = chunk.rfind(b"\n")
        if end < 0:
            return
        self._cursors[traj] = (identity_id, offset + end + 1)
        subs = load_subscriptions(self.root)
        if not subs:
            return
        for line in chunk[: end + 1].splitlines():
            try:
                step = json.loads(line)
            except json.JSONDecodeError:
                continue
            targets = notifications_for(step, subs)
            if targets:
                self._send(targets, _payload(step, identity_id))

    def _send(self, targets: list[dict], payload: str) -> None:
        from pywebpush import WebPushException, webpush

        pem_path = _store_dir(self.root) / VAPID_PEM
        if not pem_path.is_file():
            return  # no keys yet means nothing ever subscribed via this box
        for target in targets:
            try:
                webpush(
                    subscription_info=target["subscription"],
                    data=payload,
                    vapid_private_key=str(pem_path),
                    vapid_claims={"sub": getenv("HEADLONG_VAPID_SUB", "mailto:admin@example.com")},
                )
            except WebPushException as exc:
                status = getattr(exc.response, "status_code", None)
                endpoint = target["subscription"].get("endpoint", "")
                if status in (404, 410):
                    remove_subscription(self.root, endpoint)
                    log.info("pruned dead push subscription %s", endpoint[:60])
                else:
                    log.warning("web push failed (%s): %s", status, exc)

    def run(self) -> None:
        self._rescan()
        while True:
            time.sleep(self.poll_s)
            try:
                if time.monotonic() - self._last_scan > self.rescan_s:
                    self._rescan()
                for traj in list(self._cursors):
                    self._drain(traj)
            except Exception:  # noqa: BLE001 — the watcher must survive
                log.exception("push watcher tick failed")
