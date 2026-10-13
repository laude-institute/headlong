#!/usr/bin/env python3
"""Brain policy for the inference gateway: which brain answers Custos, and when it reverts.

The gateway (custos_gateway.py) keeps its interface and admission rules; this module decides, per
request, between the local backend (johan, Qwen3.8-27B) and a cloud tier reached through the ChatGPT
Codex backend with Hal's OAuth login. It lives with the gateway in LXC 131 (custos-brain); the token
never enters LXC 122.

Policy (operator, /etc/custos-brain/brain.json):
  {"window_id": "2026-09-12-frontier", "until": "2026-09-12T22:00:00Z",
   "tiers": {"astra": "gpt-6-astra", "terra": "gpt-5.6-terra"},
   "routes": {"gpt-6-astra": "astra", "gpt-5.6-terra": "terra", "*": "terra"},
   "effort": {"medium": "medium", "xhigh": "xhigh"},
   "johan": {"mac": "d8:43:ae:4d:bc:6d", "host": "johan.lan", "port": 8080},
   "tycho": {"provider": "tycho", "host": "tycho.lan", "port": 8080,
             "model": "qwen3.8-27b", "label": "tycho/qwen3.8-27b"},
   "backup": {"provider": "openrouter", "model": "deepseek/deepseek-v4.1-flash",
              "url": "https://openrouter.ai/api/v1/chat/completions",
              "key_file": "/var/lib/custos-brain/openrouter-api-key"},
   "ntfy_topic": "<uuid>", "codex_url": "https://chatgpt.com/backend-api/codex/responses"}

State (this service, /var/lib/custos-brain/state.json): {"mode": "cloud"|"local", "reason", "at",
"window_id", "quota": {...}}. The revert is sticky: once the window expires or OpenAI reports the
quota exhausted, mode is local until an operator opens a new window (a new window_id in the policy).
On a flip the service wakes johan with a magic packet and posts to Hal's ntfy topic.

Credentials: /var/lib/custos-brain/codex-auth.json (a copy of ~/.codex/auth.json, 0600). The access
token is refreshed through auth.openai.com when it is within five minutes of expiry, and the rotated
tokens are written back atomically.
"""
import argparse
import asyncio
import base64
import contextlib
import json
import os
from pathlib import Path
import socket
import ssl
import stat
import sys
import tempfile
import time
import uuid

CODEX_URL = "https://chatgpt.com/backend-api/codex/responses"
OAUTH_TOKEN_URL = "https://auth.openai.com/oauth/token"
CODEX_CLIENT_ID = "app_69a1d78e929881919bba0dbda1f6436d"   # from the installed codex-cli 0.153.4
ORIGINATOR = "codex_cli_rs"
USER_AGENT = "codex_cli_rs/0.153.4 (custos-brain)"
QUOTA_CODES = {"usage_limit_reached", "usage_not_included", "workspace_owner_usage_limit_reached",
               "workspace_member_usage_limit_reached", "workspace_owner_credits_depleted",
               "workspace_member_credits_depleted"}
MAX_UPSTREAM_BYTES = 32 * 1024 * 1024
STATE_DIR = Path("/var/lib/custos-brain")
OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"


def utc_now_iso(now=None):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now if now is not None else time.time()))


def parse_iso(value):
    """'2026-09-12T22:00:00Z' or with an offset -> epoch seconds; None if unparsable."""
    if not isinstance(value, str):
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        import datetime
        return datetime.datetime.fromisoformat(text).timestamp()
    except ValueError:
        return None


def atomic_write(path, data, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=".tmp-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp, mode)
        os.replace(temp, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temp)


def jwt_claims(token):
    try:
        part = token.split(".")[1]
        part += "=" * (-len(part) % 4)
        return json.loads(base64.urlsafe_b64decode(part))
    except (IndexError, ValueError, AttributeError):
        return {}


def magic_packet(mac):
    raw = bytes.fromhex(mac.replace(":", "").replace("-", ""))
    if len(raw) != 6:
        raise ValueError("invalid MAC")
    return b"\xff" * 6 + raw * 16


def wake_on_lan(mac, broadcast="255.255.255.255", port=9):
    packet = magic_packet(mac)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.sendto(packet, (broadcast, port))
        sock.sendto(packet, (broadcast, 7))
    return len(packet)


# --- policy and state --------------------------------------------------------------------------

def load_brain_policy(path):
    value = json.loads(Path(path).read_text())
    if not isinstance(value, dict):
        raise ValueError("brain policy must be an object")
    for key in ("window_id", "until", "tiers", "routes", "johan"):
        if key not in value:
            raise ValueError("brain policy missing " + key)
    if parse_iso(value["until"]) is None:
        raise ValueError("brain policy 'until' must be an ISO-8601 timestamp")
    if not isinstance(value["tiers"], dict) or not value["tiers"] or not all(
            isinstance(k, str) and isinstance(v, str) and v for k, v in value["tiers"].items()):
        raise ValueError("brain policy tiers must map tier names to model names")
    if not isinstance(value["routes"], dict) or "*" not in value["routes"] or not all(
            v in value["tiers"] for v in value["routes"].values()):
        raise ValueError("brain policy routes must map model names (and '*') to tiers")
    johan = value["johan"]
    if not isinstance(johan, dict) or not isinstance(johan.get("mac"), str) or not isinstance(johan.get("host"), str):
        raise ValueError("brain policy johan needs mac and host")
    magic_packet(johan["mac"])
    tycho = value.get("tycho")
    if tycho is not None:
        if (not isinstance(tycho, dict) or tycho.get("provider") != "tycho" or
                tycho.get("host") != "tycho.lan" or tycho.get("port") != 8080 or
                not isinstance(tycho.get("model"), str) or not tycho["model"] or
                not isinstance(tycho.get("label"), str) or not tycho["label"]):
            raise ValueError("brain tycho fallback must use tycho.lan:8080 with model and label")
    backup = value.get("backup")
    if backup is not None:
        if not isinstance(backup, dict) or backup.get("provider") != "openrouter":
            raise ValueError("brain backup provider must be openrouter")
        if not isinstance(backup.get("model"), str) or not backup["model"]:
            raise ValueError("brain backup needs a model")
        if not isinstance(backup.get("key_file"), str) or not Path(backup["key_file"]).is_absolute():
            raise ValueError("brain backup needs an absolute key_file")
        backup.setdefault("url", OPENROUTER_URL)
        scheme, host, _, _ = split_url(backup["url"])
        if scheme not in ("http", "https") or (scheme == "http" and host not in ("127.0.0.1", "localhost")):
            raise ValueError("brain backup URL must use HTTPS (except loopback tests)")
        routing = backup.get("provider_routing")
        if routing is not None:
            if (not isinstance(routing, dict) or set(routing) != {"only", "allow_fallbacks"} or
                    not isinstance(routing["only"], list) or not routing["only"] or
                    not all(isinstance(item, str) and item.strip() for item in routing["only"]) or
                    type(routing["allow_fallbacks"]) is not bool):
                raise ValueError("brain backup provider_routing needs a nonempty only list and boolean allow_fallbacks")
    value.setdefault("effort", {"medium": "medium", "xhigh": "xhigh"})
    value.setdefault("codex_url", CODEX_URL)
    value.setdefault("ntfy_topic", None)
    value.setdefault("local_model", "qwen3.8-27b")
    johan.setdefault("port", 8080)
    return value


class Brain:
    def __init__(self, policy, state_dir=STATE_DIR, clock=time.time, notify=None, wake=None, log=None):
        self.p = policy
        self.state_dir = Path(state_dir)
        self.clock = clock
        self.notify = notify or self.ntfy
        self.wake = wake or (lambda: wake_on_lan(self.p["johan"]["mac"]))
        self.log = log or (lambda line: print("custos-brain: " + line, flush=True))
        self.state_path = self.state_dir / "state.json"
        self.auth_path = self.state_dir / "codex-auth.json"
        self.state = self._load_state()
        self._effort_fallback = {}
        self.calls = 0
        self.backup_calls = 0
        self._active_local_route = "johan"

    # -- state ------------------------------------------------------------------------------

    def _load_state(self):
        try:
            state = json.loads(self.state_path.read_text())
            if not isinstance(state, dict) or state.get("mode") not in ("cloud", "local"):
                raise ValueError("bad state")
        except (OSError, ValueError):
            state = {"mode": "cloud", "reason": "window opened", "at": utc_now_iso(self.clock()),
                     "window_id": self.p["window_id"], "quota": {}}
            self._save_state(state)
        # A new window in the policy re-arms a sticky local state; the same window never does.
        if state.get("window_id") != self.p["window_id"]:
            state = {"mode": "cloud", "reason": "window opened: " + str(self.p["window_id"]),
                     "at": utc_now_iso(self.clock()), "window_id": self.p["window_id"], "quota": {}}
            self._save_state(state)
        return state

    def _save_state(self, state):
        atomic_write(self.state_path, json.dumps(state, indent=1, sort_keys=True), 0o600)

    def until(self):
        return parse_iso(self.p["until"])

    def mode(self, now=None):
        now = self.clock() if now is None else now
        if self.state["mode"] == "cloud" and now >= self.until():
            self.flip_local("window ended at " + self.p["until"])
        return self.state["mode"]

    def flip_local(self, reason):
        if self.state["mode"] == "local":
            return
        self.state.update({"mode": "local", "reason": reason, "at": utc_now_iso(self.clock())})
        self._save_state(self.state)
        self.log("brain -> local (" + reason + ")")
        try:
            self.wake()
            self.log("wake-on-lan sent to " + self.p["johan"]["mac"])
        except Exception as exc:  # noqa: BLE001 - the flip must complete regardless
            self.log("wake-on-lan failed: " + str(exc)[:200])
        try:
            self.notify("Custos brain back to johan (" + self.p["local_model"] + "): " + reason +
                        ". johan was sent a wake-on-LAN packet; check that it is up and serving.")
        except Exception as exc:  # noqa: BLE001
            self.log("ntfy failed: " + str(exc)[:200])

    def status(self):
        until = self.until()
        backup = self.p.get("backup")
        return {"mode": self.mode(), "window_id": self.p["window_id"], "until": self.p["until"],
                "seconds_left": max(0, int(until - self.clock())) if self.state["mode"] == "cloud" else 0,
                "tiers": self.p["tiers"], "routes": self.p["routes"], "local_model": self.p["local_model"],
                "reason": self.state.get("reason"), "since": self.state.get("at"),
                "quota": self.state.get("quota", {}), "calls": self.calls,
                "tycho": ({"model": self.p["tycho"]["model"], "label": self.p["tycho"]["label"]}
                          if self.p.get("tycho") else None),
                "backup": ({"provider": "openrouter", "model": backup["model"],
                            "ready": self.backup_ready(),
                            "active": self._active_local_route == "openrouter",
                            "calls": self.backup_calls} if backup else None),
                "active_local_route": self._active_local_route}

    def backup_model(self):
        backup = self.p.get("backup")
        return backup.get("model") if backup else None

    def tycho_model(self):
        tycho = self.p.get("tycho")
        return tycho.get("model") if tycho else None

    def tycho_label(self):
        tycho = self.p.get("tycho")
        return tycho.get("label") if tycho else None

    def tycho_upstream(self):
        tycho = self.p.get("tycho")
        return (tycho["host"], tycho["port"]) if tycho else None

    def _backup_key(self):
        backup = self.p.get("backup")
        if not backup:
            raise ValueError("backup is not configured")
        path = Path(backup["key_file"])
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        with os.fdopen(fd, "rb") as stream:
            metadata = os.fstat(stream.fileno())
            if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or
                    metadata.st_mode & 0o077):
                raise ValueError("backup key has unsafe ownership or mode")
            raw = stream.read(4097)
        if len(raw) > 4096:
            raise ValueError("backup key is too large")
        try:
            key = raw.decode("ascii").strip()
        except UnicodeDecodeError as exc:
            raise ValueError("backup key is malformed") from exc
        if not key or any(ch.isspace() for ch in key):
            raise ValueError("backup key is empty or malformed")
        return key

    def backup_ready(self):
        try:
            self._backup_key()
            return True
        except (OSError, ValueError):
            return False

    def note_local_route(self, route, reason):
        """Log and notify once per Johan/Tycho/OpenRouter transition, never per request."""
        if route not in {"johan", "tycho", "openrouter"}:
            raise ValueError("unknown local route")
        if self._active_local_route == route:
            return
        self._active_local_route = route
        if route == "tycho":
            text = "Custos brain using Tycho fallback (%s): %s" % (self.tycho_label(), reason)
        elif route == "openrouter":
            text = "Custos brain using OpenRouter fallback (%s): %s" % (self.backup_model(), reason)
        else:
            text = "Custos brain returned to johan (%s): %s" % (self.p["local_model"], reason)
        self.log(text)
        try:
            self.notify(text)
        except Exception as exc:  # noqa: BLE001 - routing must not depend on notifications
            self.log("backup transition ntfy failed: " + str(exc)[:200])

    # -- routing ------------------------------------------------------------------------------

    def accepted_models(self):
        # Labels are public request aliases, never backend URLs or destinations.
        # Local routing still follows admission policy, irrespective of the alias.
        aliases = {self.p["local_model"], self.tycho_model(), self.tycho_label(), self.backup_model()}
        return (set(self.p["routes"]) - {"*"} | set(self.p["tiers"].values()) | aliases) - {None, ""}

    def route(self, model, effort):
        tier = self.p["routes"].get(model, self.p["routes"]["*"])
        cloud_model = self.p["tiers"][tier]
        cloud_effort = self._effort_fallback.get(cloud_model) or self.p["effort"].get(effort, "medium")
        return tier, cloud_model, cloud_effort

    # -- quota ------------------------------------------------------------------------------

    def note_rate_limits(self, headers, body=None):
        """Record what OpenAI says about the allowance; flip when it is spent."""
        quota = dict(self.state.get("quota", {}))
        seen = {}
        for key, value in headers.items():
            if key.startswith("x-codex-"):
                seen[key] = value[:120]
                if "used-percent" in key or "used_percent" in key:
                    try:
                        quota[key.replace("x-codex-", "").replace("-", "_")] = float(value)
                    except ValueError:
                        pass
        limits = None
        if isinstance(body, dict):
            limits = body.get("rate_limits")
            if limits is None and isinstance(body.get("response"), dict):
                limits = body["response"].get("rate_limits")
        if isinstance(limits, dict):
            for window in ("primary_window", "secondary_window"):
                item = limits.get(window)
                if isinstance(item, dict) and isinstance(item.get("used_percent"), (int, float)):
                    quota[window + "_used_percent"] = float(item["used_percent"])
                    if isinstance(item.get("resets_at"), (int, float)):
                        quota[window + "_resets_at"] = item["resets_at"]
        if seen or limits:
            quota["observed_at"] = utc_now_iso(self.clock())
            self.state["quota"] = quota
            self._save_state(self.state)
        # Only the account's own windows count (the backend also reports side limits such as
        # x-codex-<feature>-primary-used-percent, which are not Custos's allowance).
        exhausted = [k for k in ("primary_used_percent", "secondary_used_percent", "primary_window_used_percent", "secondary_window_used_percent")
                     if isinstance(quota.get(k), (int, float)) and quota[k] >= 100]
        if exhausted and self.state["mode"] == "cloud":
            self.flip_local("quota exhausted (" + ", ".join(exhausted) + ")")
        return seen

    def note_error(self, status, body):
        """A 429 that names the allowance flips the brain; other errors pass through."""
        code = ""
        if isinstance(body, dict):
            error = body.get("error") if isinstance(body.get("error"), dict) else body
            code = str(error.get("type") or error.get("code") or "")
            if isinstance(error.get("code"), str) and error["code"] in QUOTA_CODES:
                code = error["code"]
        if status == 429 and code in QUOTA_CODES:
            self.flip_local("OpenAI reported " + code)
            return True
        return False

    # -- credentials ------------------------------------------------------------------------

    def _load_auth(self):
        value = json.loads(self.auth_path.read_text())
        tokens = value.get("tokens") or {}
        if not isinstance(tokens.get("access_token"), str) or not tokens.get("access_token"):
            raise ValueError("codex auth has no access token")
        account = tokens.get("account_id") or jwt_claims(tokens["access_token"]).get(
            "https://api.openai.com/auth", {}).get("chatgpt_account_id")
        if not account:
            raise ValueError("codex auth has no account id")
        return value, tokens, account

    async def access_token(self):
        value, tokens, account = self._load_auth()
        exp = jwt_claims(tokens["access_token"]).get("exp")
        if isinstance(exp, (int, float)) and exp - self.clock() < 300 and tokens.get("refresh_token"):
            refreshed = await self.refresh(tokens["refresh_token"])
            if refreshed:
                tokens.update({k: refreshed[k] for k in ("access_token", "refresh_token", "id_token") if refreshed.get(k)})
                value["tokens"] = tokens
                value["last_refresh"] = utc_now_iso(self.clock())
                atomic_write(self.auth_path, json.dumps(value, indent=2), 0o600)
                self.log("access token refreshed")
        return tokens["access_token"], account

    async def refresh(self, refresh_token):
        body = json.dumps({"grant_type": "refresh_token", "refresh_token": refresh_token,
                           "client_id": CODEX_CLIENT_ID, "scope": "openid profile email"}).encode()
        try:
            status, headers, payload = await http_request("POST", self.p.get("oauth_url", OAUTH_TOKEN_URL), body,
                                                          {"Content-Type": "application/json"}, timeout=20)
        except (OSError, ValueError, asyncio.TimeoutError) as exc:
            self.log("token refresh failed: " + str(exc)[:200])
            return None
        if status != 200:
            self.log("token refresh rejected: HTTP %d" % status)
            return None
        try:
            return json.loads(payload)
        except ValueError:
            return None

    # -- notifications ------------------------------------------------------------------------

    def ntfy(self, text, title="Custos brain"):
        topic = self.p.get("ntfy_topic")
        if not topic:
            return
        import urllib.request
        request = urllib.request.Request("https://ntfy.sh/" + topic, data=text.encode(),
                                         headers={"Title": title, "Content-Type": "text/plain"})
        with urllib.request.urlopen(request, timeout=10) as response:
            response.read(1024)

    # -- the cloud call -------------------------------------------------------------------------

    def responses_request(self, chat, cloud_model, cloud_effort):
        """Translate a (validated) chat-completions body into a Codex Responses request body."""
        instructions, inputs = [], []
        for message in chat["messages"]:
            role, content = message.get("role"), message.get("content")
            text = content if isinstance(content, str) else "\n".join(
                part["text"] for part in (content or []) if isinstance(part, dict) and part.get("type") == "text")
            if role in ("system", "developer"):
                instructions.append(text)
            elif role == "assistant":
                inputs.append({"type": "message", "role": "assistant",
                               "content": [{"type": "output_text", "text": text}]})
            else:
                inputs.append({"type": "message", "role": "user",
                               "content": [{"type": "input_text", "text": text}]})
        if not instructions:
            instructions = ["You are a helpful assistant."]
        body = {"model": cloud_model, "instructions": "\n\n".join(instructions), "input": inputs,
                "tools": [], "tool_choice": "auto", "parallel_tool_calls": False,
                "reasoning": {"effort": cloud_effort, "summary": "auto"},
                "store": False, "stream": True, "include": ["reasoning.encrypted_content"],
                "prompt_cache_key": "custos-brain"}
        # No output cap: the Codex backend rejects max_output_tokens ("Unsupported parameter",
        # 2026-09-11); the client's max_tokens is honoured by johan only.
        return body

    async def complete(self, chat, emit, request_id=None):
        """Run one completion through Codex. `emit(bytes)` receives chat-completion output
        (SSE chunks when chat['stream'] is true, else one JSON document). Returns (status, error_json)
        where status 200 means the output was emitted."""
        started = time.monotonic()
        tier, cloud_model, cloud_effort = self.route(chat.get("model"), chat.get("reasoning_effort", "xhigh"))
        token, account = await self.access_token()
        headers = {"Authorization": "Bearer " + token, "chatgpt-account-id": account,
                   "OpenAI-Beta": "responses=experimental", "originator": ORIGINATOR,
                   "User-Agent": USER_AGENT, "Accept": "text/event-stream",
                   "Content-Type": "application/json", "session_id": request_id or str(uuid.uuid4())}
        body = json.dumps(self.responses_request(chat, cloud_model, cloud_effort)).encode()
        self.calls += 1
        completion_id = "chatcmpl-" + uuid.uuid4().hex[:24]
        created = int(self.clock())
        stream = bool(chat.get("stream"))
        text_parts, reasoning_parts, usage, finish = [], [], {}, "stop"

        def chunk(delta, finish_reason=None, with_usage=None):
            item = {"id": completion_id, "object": "chat.completion.chunk", "created": created,
                    "model": cloud_model, "choices": [{"index": 0, "delta": delta, "finish_reason": finish_reason}]}
            if with_usage:
                item["usage"] = with_usage
            return ("data: " + json.dumps(item, ensure_ascii=False) + "\n\n").encode()

        status, resp_headers, first = await open_sse("POST", self.p["codex_url"], body, headers,
                                                     timeout=self.p.get("connect_seconds", 20))
        reader, closer = first
        try:
            seen = self.note_rate_limits(resp_headers)
            if status != 200:
                raw = await read_all(reader, 262144)
                try:
                    error_body = json.loads(raw) if raw else {}
                except ValueError:
                    error_body = {"error": {"type": "upstream_error", "message": raw[:300].decode("utf-8", "replace")}}
                if status == 400 and "effort" in json.dumps(error_body) and cloud_model not in self._effort_fallback:
                    self._effort_fallback[cloud_model] = "high"
                    self.log("effort %s rejected for %s; falling back to high" % (cloud_effort, cloud_model))
                flipped = self.note_error(status, error_body)
                self.log("call %s/%s effort=%s -> HTTP %d%s %s %s" % (tier, cloud_model, cloud_effort, status,
                                                                      " (quota flip)" if flipped else "", json.dumps(seen),
                                                                      json.dumps(error_body)[:300]))
                return status, error_body
            if stream:
                emit(chunk({"role": "assistant", "content": ""}))
            async for event, data in sse_events(reader):
                if event == "response.output_text.delta":
                    delta = data.get("delta", "")
                    if delta:
                        text_parts.append(delta)
                        if stream:
                            emit(chunk({"content": delta}))
                elif event == "response.reasoning_summary_text.delta":
                    delta = data.get("delta", "")
                    if delta:
                        reasoning_parts.append(delta)
                        if stream:
                            emit(chunk({"reasoning_content": delta}))
                elif event == "response.completed":
                    response = data.get("response") or {}
                    u = response.get("usage") or {}
                    usage = {"prompt_tokens": u.get("input_tokens", 0), "completion_tokens": u.get("output_tokens", 0),
                             "total_tokens": u.get("total_tokens", (u.get("input_tokens", 0) or 0) + (u.get("output_tokens", 0) or 0))}
                    self.note_rate_limits({}, data)
                    if response.get("status") == "incomplete":
                        finish = "length"
                elif event in ("response.failed", "error"):
                    err = (data.get("response") or {}).get("error") or data.get("error") or data
                    self.log("call %s/%s failed mid-stream: %s" % (tier, cloud_model, json.dumps(err)[:300]))
                    if stream:
                        emit(chunk({}, "stop"))
                        emit(b"data: [DONE]\n\n")
                        return 200, None
                    return 502, {"error": {"type": "upstream_error", "code": "response_failed", "message": json.dumps(err)[:300]}}
            if stream:
                emit(chunk({}, finish, usage))
                emit(b"data: [DONE]\n\n")
            else:
                document = {"id": completion_id, "object": "chat.completion", "created": created, "model": cloud_model,
                            "choices": [{"index": 0, "message": {"role": "assistant", "content": "".join(text_parts),
                                                                 **({"reasoning_content": "".join(reasoning_parts)} if reasoning_parts else {})},
                                         "finish_reason": finish}], "usage": usage}
                emit(json.dumps(document, ensure_ascii=False).encode())
            self.log("call %s/%s effort=%s -> 200 in %.1fs, %s tokens out, %s" % (
                tier, cloud_model, cloud_effort, time.monotonic() - started, usage.get("completion_tokens", "?"), json.dumps(seen)))
            return 200, None
        finally:
            await closer()

    async def complete_backup(self, chat, emit, request_id=None):
        """Forward one already-validated Chat Completions request to OpenRouter.

        The backup keeps the gateway's wire format, output bounds and client deadline.  It is
        intentionally a separate method from the Codex cloud window: the gateway calls it only
        after local-Johan admission has proved unavailable, never merely because Johan is busy.
        """
        backup = self.p.get("backup")
        if not backup:
            return 503, {"error": {"type": "backup_unavailable", "code": "backup_not_configured"}}
        try:
            key = self._backup_key()
        except (OSError, ValueError) as exc:
            self.log("OpenRouter backup key unavailable: " + str(exc)[:200])
            return 503, {"error": {"type": "backup_unavailable", "code": "backup_not_ready"}}

        request = dict(chat)
        request["model"] = backup["model"]
        if backup.get("provider_routing") is not None:
            request["provider"] = backup["provider_routing"]
        body = json.dumps(request, ensure_ascii=False, allow_nan=False,
                          separators=(",", ":")).encode("utf-8")
        headers = {"Authorization": "Bearer " + key,
                   "Content-Type": "application/json",
                   "Accept": "text/event-stream" if request.get("stream") else "application/json",
                   "HTTP-Referer": "https://1f916.ai",
                   "X-OpenRouter-Title": "Custos",
                   "X-Request-ID": request_id or str(uuid.uuid4())}
        started = time.monotonic()
        self.backup_calls += 1
        try:
            status, response_headers, (reader, closer) = await open_sse(
                "POST", backup["url"], body, headers,
                timeout=self.p.get("connect_seconds", 20))
            try:
                if response_headers.get("content-encoding", "identity").lower() != "identity":
                    raise ValueError("unsupported OpenRouter content encoding")
                if status != 200:
                    raw = await read_all(reader, 262144)
                    try:
                        received = json.loads(raw) if raw else {}
                    except ValueError:
                        received = {}
                    inner = received.get("error") if isinstance(received, dict) else None
                    code = (inner.get("code") or inner.get("type")) if isinstance(inner, dict) else None
                    safe = {"error": {"type": "backup_upstream_error",
                                      "code": str(code or "openrouter_http_%d" % status)[:80]}}
                    self.log("OpenRouter backup -> HTTP %d (%s)" % (status, safe["error"]["code"]))
                    return status, safe
                expected = "text/event-stream" if request.get("stream") else "application/json"
                received_type = response_headers.get("content-type", "").split(";", 1)[0].lower()
                if received_type != expected:
                    raise ValueError("unexpected OpenRouter content type")
                async for data in reader:
                    emit(data)
                self.log("OpenRouter backup/%s -> 200 in %.1fs" %
                         (backup["model"], time.monotonic() - started))
                return 200, None
            finally:
                await closer()
        except (OSError, ValueError, asyncio.TimeoutError) as exc:
            self.log("OpenRouter backup transport unavailable: %s: %s" %
                     (type(exc).__name__, str(exc)[:200]))
            return 503, {"error": {"type": "backup_unavailable",
                                   "code": "backup_transport_unavailable"}}


# --- minimal HTTP/1.1 client over asyncio (stdlib only) ----------------------------------------

def split_url(url):
    scheme, rest = url.split("://", 1)
    host, _, path = rest.partition("/")
    port = 443 if scheme == "https" else 80
    if ":" in host:
        host, port = host.rsplit(":", 1)
        port = int(port)
    return scheme, host, port, "/" + path


async def open_sse(method, url, body, headers, timeout=20):
    scheme, host, port, path = split_url(url)
    context = ssl.create_default_context() if scheme == "https" else None
    reader, writer = await asyncio.wait_for(
        asyncio.open_connection(host, port, ssl=context, server_hostname=host if context else None, limit=1 << 20), timeout)
    lines = ["%s %s HTTP/1.1" % (method, path), "Host: " + host, "Connection: close", "Content-Length: %d" % len(body)]
    lines += ["%s: %s" % (k, v) for k, v in headers.items()]
    writer.write(("\r\n".join(lines) + "\r\n\r\n").encode() + body)
    await asyncio.wait_for(writer.drain(), timeout)
    raw = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout)
    head = raw[:-4].decode("iso-8859-1").split("\r\n")
    status = int(head[0].split(" ", 2)[1])
    resp_headers = {}
    for line in head[1:]:
        key, _, value = line.partition(":")
        resp_headers[key.strip().lower()] = value.strip()
    body_reader = dechunked(reader, resp_headers)

    async def closer():
        writer.close()
        with contextlib.suppress(Exception):
            await asyncio.wait_for(writer.wait_closed(), 1)
    return status, resp_headers, (body_reader, closer)


async def dechunked(reader, headers):
    """Yield body bytes, handling chunked transfer encoding and bounding the total."""
    total = 0
    if headers.get("transfer-encoding", "").lower() == "chunked":
        while True:
            size_line = await reader.readuntil(b"\r\n")
            size = int(size_line.strip().split(b";")[0] or b"0", 16)
            if size == 0:
                with contextlib.suppress(asyncio.IncompleteReadError):
                    await reader.readuntil(b"\r\n")
                return
            data = await reader.readexactly(size)
            await reader.readexactly(2)
            total += len(data)
            if total > MAX_UPSTREAM_BYTES:
                raise ValueError("upstream response too large")
            yield data
    else:
        remaining = int(headers.get("content-length", "0") or 0) if "content-length" in headers else None
        while remaining is None or remaining > 0:
            data = await reader.read(min(65536, remaining) if remaining is not None else 65536)
            if not data:
                return
            if remaining is not None:
                remaining -= len(data)
            total += len(data)
            if total > MAX_UPSTREAM_BYTES:
                raise ValueError("upstream response too large")
            yield data


async def read_all(body, limit):
    parts, total = [], 0
    async for data in body:
        total += len(data)
        if total > limit:
            break
        parts.append(data)
    return b"".join(parts)


async def sse_events(body):
    """Yield (event, data-json) tuples from a Server-Sent-Events body."""
    buffer = b""
    event, data_lines = None, []
    async for data in body:
        buffer += data
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            line = line.rstrip(b"\r")
            if not line:
                if data_lines:
                    payload = b"\n".join(data_lines).decode("utf-8", "replace")
                    if payload.strip() != "[DONE]":
                        try:
                            parsed = json.loads(payload)
                        except ValueError:
                            parsed = {"raw": payload[:500]}
                        name = event or (parsed.get("type") if isinstance(parsed, dict) else None)
                        yield name, parsed
                event, data_lines = None, []
                continue
            if line.startswith(b"event:"):
                event = line[6:].strip().decode()
            elif line.startswith(b"data:"):
                data_lines.append(line[5:].strip())


async def http_request(method, url, body, headers, timeout=20):
    status, resp_headers, (reader, closer) = await open_sse(method, url, body, headers, timeout)
    try:
        return status, resp_headers, await read_all(reader, 1 << 20)
    finally:
        await closer()


# --- CLI ------------------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", default="/etc/custos-brain/brain.json")
    parser.add_argument("--state-dir", default=str(STATE_DIR))
    parser.add_argument("--status", action="store_true", help="print the brain status and exit")
    parser.add_argument("--simulate-flip", action="store_true",
                        help="rehearse the revert against a scratch copy of the state: sends the wake-on-LAN packet and a rehearsal ntfy, writes nothing to the live state")
    parser.add_argument("--wake-johan", action="store_true", help="send the wake-on-LAN packet only")
    args = parser.parse_args(argv)
    policy = load_brain_policy(args.policy)
    if args.wake_johan:
        print("sent %d bytes to %s" % (wake_on_lan(policy["johan"]["mac"]), policy["johan"]["mac"]))
        return 0
    if args.simulate_flip:
        with tempfile.TemporaryDirectory() as scratch:
            brain = Brain(policy, state_dir=scratch)
            brain.notify = lambda text: Brain.ntfy(brain, "[rehearsal] " + text)
            brain.flip_local("rehearsal")
            print(json.dumps(brain.status(), indent=1))
        return 0
    brain = Brain(policy, state_dir=args.state_dir)
    print(json.dumps(brain.status(), indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
