"""Web push: key generation, subscription store, and watcher matching."""

import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from headlong_web import push
from headlong_web.server import create_app

ROOT_TRAJ = "abababab-7777-4777-8777-777777777777"

SUB = {
    "endpoint": "https://push.example.com/send/abc123",
    "keys": {"p256dh": "BPubKey", "auth": "authsecret"},
}


@pytest.fixture
def push_root(tmp_path: Path) -> Path:
    identity = tmp_path / ".identities" / "pushy"
    identity.mkdir(parents=True)
    (identity / "info.txt").write_text(
        f"name=pushy\ncreated=2026-08-05T00:00:00\nroot_trajectory={ROOT_TRAJ}\n"
    )
    traj_dir = identity / "trajectories" / "abababab-root"
    traj_dir.mkdir(parents=True)
    (traj_dir / "trajectory.jsonl").write_text(
        json.dumps({"type": "trajectory", "step_id": ROOT_TRAJ, "ts": "t0"}) + "\n"
    )
    return tmp_path


@pytest.fixture
def client(push_root: Path) -> TestClient:
    return TestClient(create_app(push_root))


def test_push_key_generated_and_stable(client: TestClient, push_root: Path):
    first = client.get("/api/push/key").json()["key"]
    assert first and "=" not in first  # b64url, unpadded
    assert (push_root / ".web-push" / "vapid_private.pem").is_file()
    assert client.get("/api/push/key").json()["key"] == first


def test_subscribe_upserts_by_endpoint(client: TestClient, push_root: Path):
    body = {"name": "pwa-nick", "subscription": SUB}
    assert client.post("/api/push/subscriptions", json=body).json()["subscriptions"] == 1
    assert client.post("/api/push/subscriptions", json=body).json()["subscriptions"] == 1
    assert len(push.load_subscriptions(push_root)) == 1


def test_subscribe_validation(client: TestClient):
    bad_name = {"name": "slack-U1-C1", "subscription": SUB}
    assert client.post("/api/push/subscriptions", json=bad_name).status_code == 422
    bad_sub = {"name": "pwa-nick", "subscription": {"endpoint": "http://not-tls"}}
    assert client.post("/api/push/subscriptions", json=bad_sub).status_code == 422


def test_unsubscribe(client: TestClient):
    client.post(
        "/api/push/subscriptions", json={"name": "pwa-nick", "subscription": SUB}
    )
    ok = client.post(
        "/api/push/unsubscribe", json={"endpoint": SUB["endpoint"]}
    ).json()
    assert ok["removed"] is True
    again = client.post(
        "/api/push/unsubscribe", json={"endpoint": SUB["endpoint"]}
    ).json()
    assert again["removed"] is False


def test_notifications_for_matching():
    subs = [{"name": "pwa-nick", "subscription": SUB}]
    hit = {"type": "message", "from": "pushy", "to": "pwa-nick", "content": "hi"}
    assert push.notifications_for(hit, subs) == subs
    for miss in [
        {"type": "thought", "to": "pwa-nick", "content": "x"},
        {"type": "message", "to": "slack-U1-C1", "content": "x"},
        {"type": "message", "to": "pwa-boss", "content": "x"},
        {"type": "message", "to": "pwa-nick", "content": ""},
    ]:
        assert push.notifications_for(miss, subs) == []


def test_watcher_drains_only_new_complete_lines(push_root: Path, monkeypatch):
    push.add_subscription(push_root, "pwa-nick", SUB)
    watcher = push.PushWatcher(push_root)
    watcher._rescan()
    assert len(watcher._cursors) == 1

    sent: list[str] = []
    monkeypatch.setattr(
        watcher, "_send", lambda targets, payload: sent.append(payload)
    )
    traj = next(iter(watcher._cursors))

    # Pre-existing history must never replay: drain now sends nothing.
    watcher._drain(traj)
    assert sent == []

    with traj.open("a") as fh:
        fh.write(
            json.dumps(
                {"type": "message", "from": "pushy", "to": "pwa-nick", "content": "ping"}
            )
            + "\n"
        )
        fh.write('{"type": "message", "to": "pwa-nick", "content": "half')  # no \n
    watcher._drain(traj)
    assert len(sent) == 1
    payload = json.loads(sent[0])
    assert payload["title"] == "pushy"
    assert payload["body"] == "ping"
    assert payload["url"] == "/talk/.identities~pushy"

    # The partial line stays buffered until its newline arrives.
    watcher._drain(traj)
    assert len(sent) == 1
    with traj.open("a") as fh:
        fh.write(' now complete"}\n')
    watcher._drain(traj)
    assert len(sent) == 2


@pytest.mark.parametrize("replacement", [b"", b'{"type":"message","to":"pwa-nick","content":"old"}\n'])
def test_watcher_recovers_after_shrink_without_replaying_history(
    push_root: Path, monkeypatch, replacement: bytes
):
    push.add_subscription(push_root, "pwa-nick", SUB)
    watcher = push.PushWatcher(push_root)
    watcher._rescan()
    traj = next(iter(watcher._cursors))
    sent = []
    monkeypatch.setattr(watcher, "_send", lambda targets, payload: sent.append(json.loads(payload)))
    traj.write_bytes(replacement)
    watcher._drain(traj)
    assert sent == []
    assert watcher._cursors[traj][1] == len(replacement)
    fresh = {"type": "message", "from": "pushy", "to": "pwa-nick", "content": "new"}
    with traj.open("ab") as stream:
        stream.write(json.dumps(fresh).encode() + b"\n")
    watcher._drain(traj)
    watcher._drain(traj)
    assert [payload["body"] for payload in sent] == ["new"]
    assert sent[0]["url"] == "/talk/.identities~pushy"
