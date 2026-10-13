"""custos_brain: brain policy, sticky revert, Codex transport, and the gateway's cloud path.

Runs hermetically: a fake Codex backend on 127.0.0.1 speaks the Responses SSE shape, wake-on-LAN
and ntfy are captured, the clock is a fixture value.
"""
import asyncio
import base64
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import custos_brain as brain_mod
import custos_gateway as gateway

T0 = 1789200000.0  # 2026-09-12T08:00:00Z


def fake_jwt(exp):
    header = base64.urlsafe_b64encode(b'{"alg":"none"}').decode().rstrip("=")
    claims = base64.urlsafe_b64encode(json.dumps({"exp": exp, "https://api.openai.com/auth": {"chatgpt_account_id": "acct-1"}}).encode()).decode().rstrip("=")
    return header + "." + claims + ".sig"


def policy(**changes):
    value = {"window_id": "w1", "until": "2026-09-13T08:00:00Z",
             "tiers": {"astra": "gpt-6-astra", "terra": "gpt-5.6-terra"},
             "routes": {"gpt-6-astra": "astra", "gpt-5.6-terra": "terra", "*": "terra"},
             "johan": {"mac": "d8:43:ae:4d:bc:6d", "host": "johan.lan"}, "ntfy_topic": None}
    value.update(changes)
    return brain_mod.load_brain_policy_dict(value) if hasattr(brain_mod, "load_brain_policy_dict") else _load(value)


def _load(value):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(value, handle)
    return brain_mod.load_brain_policy(handle.name)


class ProviderRoutingPolicyTests(unittest.TestCase):
    def test_provider_selection_is_validated(self):
        backup = {"provider": "openrouter", "model": "xiaomi/mimo-v2.6-pro",
                  "key_file": "/var/lib/custos-brain/openrouter-api-key"}
        routing = {"only": ["xiaomi"], "allow_fallbacks": False}
        self.assertEqual(policy(backup={**backup, "provider_routing": routing})["backup"]["provider_routing"], routing)
        for bad in [[], {}, {"only": [], "allow_fallbacks": False},
                    {"only": [""], "allow_fallbacks": False},
                    {"only": ["xiaomi"], "allow_fallbacks": "false"},
                    {"only": ["xiaomi"], "allow_fallbacks": False, "url": "https://example.test"}]:
            with self.subTest(routing=bad), self.assertRaises(ValueError):
                policy(backup={**backup, "provider_routing": bad})


class Fixture:
    def __init__(self, directory, **changes):
        self.now = T0
        self.woken, self.notices = [], []
        self.p = policy(**changes)
        self.brain = brain_mod.Brain(self.p, state_dir=directory, clock=lambda: self.now,
                                     notify=self.notices.append, wake=lambda: self.woken.append(self.p["johan"]["mac"]),
                                     log=lambda line: None)
        Path(directory, "codex-auth.json").write_text(json.dumps({"tokens": {"access_token": fake_jwt(T0 + 86400 * 5), "account_id": "acct-1", "refresh_token": "r"}}))


class PolicyAndStateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)

    def test_policy_validation(self):
        for bad in ({"until": "soon"}, {"routes": {"gpt-6-astra": "astra"}}, {"routes": {"*": "nope"}}, {"johan": {"mac": "zz", "host": "x"}}):
            with self.assertRaises(ValueError):
                policy(**bad)
        p = policy()
        self.assertEqual(p["effort"], {"medium": "medium", "xhigh": "xhigh"}); self.assertEqual(p["codex_url"], brain_mod.CODEX_URL)
        with self.assertRaises(ValueError):
            policy(backup={"provider": "openrouter", "model": "x", "url": "http://example.test/v1",
                           "key_file": "/tmp/key"})
        with self.assertRaises(ValueError):
            policy(tycho={"provider": "tycho", "host": "192.168.86.104", "port": 8080,
                          "model": "q", "label": "tycho/q"})

    def test_backup_key_requires_private_file_owned_by_service_user(self):
        key = Path(self.temp.name, "key")
        key.write_text("secret")
        key.chmod(0o600)
        f = Fixture(self.temp.name, backup={"provider": "openrouter", "model": "deepseek/test",
                                           "url": "http://127.0.0.1:9/v1/chat/completions",
                                           "key_file": str(key)})
        self.assertTrue(f.brain.backup_ready())
        self.assertEqual(f.brain._backup_key(), "secret")
        key.chmod(0o640)
        self.assertFalse(f.brain.backup_ready())
        key.chmod(0o600)
        link = Path(self.temp.name, "key-link")
        link.symlink_to(key)
        f.p["backup"]["key_file"] = str(link)
        self.assertFalse(f.brain.backup_ready())

    def test_fresh_state_is_cloud_and_persists(self):
        f = Fixture(self.temp.name)
        self.assertEqual(f.brain.mode(), "cloud")
        state = json.loads(Path(self.temp.name, "state.json").read_text())
        self.assertEqual(state["mode"], "cloud"); self.assertEqual(state["window_id"], "w1")
        self.assertEqual(f.brain.status()["seconds_left"], 86400)

    def test_expiry_flips_to_local_sticky_and_wakes_johan(self):
        f = Fixture(self.temp.name)
        f.now = T0 + 86400
        self.assertEqual(f.brain.mode(), "local")
        self.assertEqual(f.woken, ["d8:43:ae:4d:bc:6d"]); self.assertIn("window ended", f.notices[0])
        # Sticky: an earlier clock (or a restart) does not re-arm the same window.
        f.now = T0
        self.assertEqual(f.brain.mode(), "local")
        again = brain_mod.Brain(f.p, state_dir=self.temp.name, clock=lambda: T0, notify=lambda t: None, wake=lambda: None, log=lambda l: None)
        self.assertEqual(again.mode(), "local"); self.assertEqual(again.status()["seconds_left"], 0)

    def test_new_window_id_rearms(self):
        f = Fixture(self.temp.name)
        f.brain.flip_local("test")
        renewed = brain_mod.Brain(policy(window_id="w2"), state_dir=self.temp.name, clock=lambda: T0, notify=lambda t: None, wake=lambda: None, log=lambda l: None)
        self.assertEqual(renewed.mode(), "cloud"); self.assertIn("w2", renewed.state["reason"])

    def test_routes_and_accepted_models(self):
        f = Fixture(self.temp.name)
        self.assertEqual(f.brain.route("gpt-6-astra", "xhigh"), ("astra", "gpt-6-astra", "xhigh"))
        self.assertEqual(f.brain.route("gpt-5.6-terra", "medium"), ("terra", "gpt-5.6-terra", "medium"))
        self.assertEqual(f.brain.route("qwen3.8-27b", "xhigh"), ("terra", "gpt-5.6-terra", "xhigh"))
        self.assertEqual(f.brain.accepted_models(), {"gpt-6-astra", "gpt-5.6-terra", "qwen3.8-27b"})

    def test_quota_headers_and_body_flip_at_100(self):
        f = Fixture(self.temp.name)
        seen = f.brain.note_rate_limits({"x-codex-primary-used-percent": "42.5", "content-type": "text/event-stream"})
        self.assertEqual(seen, {"x-codex-primary-used-percent": "42.5"})
        self.assertEqual(f.brain.status()["quota"]["primary_used_percent"], 42.5); self.assertEqual(f.brain.mode(), "cloud")
        f.brain.note_rate_limits({}, {"type": "response.completed", "response": {"rate_limits": {"primary_window": {"used_percent": 100, "resets_at": 1}}}})
        self.assertEqual(f.brain.mode(), "local"); self.assertIn("quota exhausted", f.brain.state["reason"]); self.assertEqual(len(f.woken), 1)

    def test_429_usage_limit_flips_but_plain_rate_limit_does_not(self):
        f = Fixture(self.temp.name)
        self.assertFalse(f.brain.note_error(429, {"error": {"type": "rate_limit_exceeded", "message": "slow down"}}))
        self.assertEqual(f.brain.mode(), "cloud")
        self.assertTrue(f.brain.note_error(429, {"error": {"type": "usage_limit_reached", "message": "weekly limit"}}))
        self.assertEqual(f.brain.mode(), "local"); self.assertIn("usage_limit_reached", f.brain.state["reason"])

    def test_chat_to_responses_translation(self):
        f = Fixture(self.temp.name)
        chat = {"model": "gpt-6-astra", "reasoning_effort": "xhigh", "max_tokens": 1234, "stream": True,
                "messages": [{"role": "system", "content": "be terse"}, {"role": "user", "content": [{"type": "text", "text": "hi"}]},
                             {"role": "assistant", "content": "hello"}, {"role": "user", "content": "go"}]}
        body = f.brain.responses_request(chat, "gpt-6-astra", "xhigh")
        self.assertEqual(body["instructions"], "be terse"); self.assertEqual(body["model"], "gpt-6-astra")
        self.assertEqual([m["role"] for m in body["input"]], ["user", "assistant", "user"])
        self.assertEqual(body["input"][1]["content"][0]["type"], "output_text"); self.assertEqual(body["input"][0]["content"][0]["text"], "hi")
        self.assertEqual(body["reasoning"], {"effort": "xhigh", "summary": "auto"}); self.assertNotIn("max_output_tokens", body)
        self.assertFalse(body["store"]); self.assertTrue(body["stream"])

    def test_magic_packet(self):
        packet = brain_mod.magic_packet("d8:43:ae:4d:bc:6d")
        self.assertEqual(len(packet), 102); self.assertEqual(packet[:6], b"\xff" * 6); self.assertEqual(packet[6:12], bytes.fromhex("d843ae4dbc6d"))


class SseParserTests(unittest.IsolatedAsyncioTestCase):
    async def test_events_are_parsed_across_chunk_boundaries(self):
        raw = (b'event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"he"}\n\n'
               b'data: {"type":"response.output_text.delta","delta":"llo"}\n\n'
               b'event: response.completed\ndata: {"type":"response.completed","response":{"usage":{"input_tokens":3,"output_tokens":2}}}\n\ndata: [DONE]\n\n')
        async def body():
            yield raw[:20]; yield raw[20:57]; yield raw[57:]
        events = [(e, d) async for e, d in brain_mod.sse_events(body())]
        self.assertEqual([e for e, _ in events], ["response.output_text.delta", "response.output_text.delta", "response.completed"])
        self.assertEqual(events[1][1]["delta"], "llo")


class CloudWireTests(unittest.IsolatedAsyncioTestCase):
    """The gateway in cloud mode against a fake Codex backend; then the flip to johan."""

    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.now = T0
        self.codex_calls, self.openrouter_calls = [], []
        self.johan_calls, self.tycho_calls, self.tasks = 0, 0, set()
        self.codex_mode = "ok"
        self.codex = await asyncio.start_server(self.codex_handle, "127.0.0.1", 0)
        self.openrouter = await asyncio.start_server(self.openrouter_handle, "127.0.0.1", 0)
        self.johan = await asyncio.start_server(self.johan_handle, "127.0.0.1", 0)
        self.tycho = await asyncio.start_server(self.tycho_handle, "127.0.0.1", 0)
        codex_port = self.codex.sockets[0].getsockname()[1]
        openrouter_port = self.openrouter.sockets[0].getsockname()[1]
        tycho_port = self.tycho.sockets[0].getsockname()[1]
        self.backup_key = Path(self.directory.name, "openrouter-key")
        self.backup_key.write_text("test-key")
        self.backup_key.chmod(0o600)
        self.woken, self.notices = [], []
        p = policy(codex_url="http://127.0.0.1:%d/backend-api/codex/responses" % codex_port,
                   tycho={"provider": "tycho", "host": "tycho.lan", "port": 8080,
                          "model": "qwen3.8-27b", "label": "tycho/qwen3.8-27b"},
                   backup={"provider": "openrouter", "model": "deepseek/deepseek-v4.1-flash",
                           "url": "http://127.0.0.1:%d/v1/chat/completions" % openrouter_port,
                           "key_file": str(self.backup_key)})
        self.brain = brain_mod.Brain(p, state_dir=self.directory.name, clock=lambda: self.now,
                                     notify=self.notices.append, wake=lambda: self.woken.append(1), log=lambda line: None)
        Path(self.directory.name, "codex-auth.json").write_text(json.dumps({"tokens": {"access_token": fake_jwt(T0 + 86400 * 5), "account_id": "acct-1"}}))
        # Tests keep the policy's production-safe name but inject the loopback endpoint after
        # validation; production code never accepts an arbitrary Tycho destination.
        self.brain.p["tycho"]["host"], self.brain.p["tycho"]["port"] = self.tycho.sockets[0].getsockname()[:2]
        gp = gateway.load_policy(Path(__file__).resolve().parents[1] / "gateway-policy.json")
        gp.update(allowed_clients=["127.0.0.1"], pause_file=str(Path(self.directory.name) / "paused"))

        class Busy:
            stale = False
            occupied = False
            def check(self, now, admission=True):
                if self.stale:
                    raise gateway.Denied(503, "busy_observation_unavailable", 30)
                if admission and self.occupied:
                    raise gateway.Denied(503, "backend_busy_or_unavailable", 30)
                return None
        self.busy = Busy()
        self.gateway = gateway.Gateway(gp, busy=self.busy, clock=lambda: self.now,
                                       upstream=self.johan.sockets[0].getsockname()[:2], brain=self.brain)
        self.server = await asyncio.start_server(self.gateway.accept, "127.0.0.1", 0, limit=gp["max_header_bytes"])
        self.address = self.server.sockets[0].getsockname()[:2]

    async def asyncTearDown(self):
        for server in (self.server, self.codex, self.openrouter, self.johan, self.tycho):
            server.close(); await server.wait_closed()
        tasks = list(self.gateway.tasks | self.tasks)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        self.directory.cleanup()

    async def codex_handle(self, reader, writer):
        self.tasks.add(asyncio.current_task())
        try:
            line, headers = await gateway.read_headers(reader, 65536)
            body = json.loads(await reader.readexactly(int(headers["content-length"])))
            self.codex_calls.append((line, headers, body))
            if self.codex_mode == "quota":
                payload = json.dumps({"error": {"type": "usage_limit_reached", "message": "You have hit your usage limit"}}).encode()
                writer.write(b"HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % len(payload) + payload)
            else:
                events = [("response.output_text.delta", {"type": "response.output_text.delta", "delta": "Hi "}),
                          ("response.reasoning_summary_text.delta", {"type": "response.reasoning_summary_text.delta", "delta": "thinking"}),
                          ("response.output_text.delta", {"type": "response.output_text.delta", "delta": "Hal"}),
                          ("response.completed", {"type": "response.completed", "response": {"status": "completed", "usage": {"input_tokens": 7, "output_tokens": 2},
                                                                                              "rate_limits": {"primary_window": {"used_percent": 61.0}}}})]
                writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nx-codex-primary-used-percent: 61\r\n\r\n")
                for name, data in events:
                    chunk = ("event: %s\ndata: %s\n\n" % (name, json.dumps(data))).encode()
                    writer.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                writer.write(b"0\r\n\r\n")
            await writer.drain()
        finally:
            await gateway.close_writer(writer)

    async def johan_handle(self, reader, writer):
        self.tasks.add(asyncio.current_task())
        try:
            _, headers = await gateway.read_headers(reader, 16384)
            body = json.loads(await reader.readexactly(int(headers["content-length"])))
            self.johan_calls += 1
            self.johan_model = body.get("model")
            sse = b'data: {"choices":[{"delta":{"content":"local"}}]}\n\ndata: [DONE]\n\n'
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
            writer.write(f"{len(sse):x}\r\n".encode() + sse + b"\r\n0\r\n\r\n")
            await writer.drain()
        finally:
            await gateway.close_writer(writer)

    async def openrouter_handle(self, reader, writer):
        self.tasks.add(asyncio.current_task())
        try:
            line, headers = await gateway.read_headers(reader, 16384)
            body = json.loads(await reader.readexactly(int(headers["content-length"])))
            self.openrouter_calls.append((line, headers, body))
            if body.get("stream"):
                response = b'data: {"choices":[{"delta":{"content":"backup"}}]}\n\ndata: [DONE]\n\n'
                writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: " +
                             str(len(response)).encode() + b"\r\n\r\n" + response)
            else:
                response = json.dumps({"choices": [{"message": {"role": "assistant", "content": "backup"}}]}).encode()
                writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " +
                             str(len(response)).encode() + b"\r\n\r\n" + response)
            await writer.drain()
        finally:
            await gateway.close_writer(writer)

    async def tycho_handle(self, reader, writer):
        self.tasks.add(asyncio.current_task())
        try:
            line, headers = await gateway.read_headers(reader, 16384)
            if line.startswith("GET /health"):
                response = b'{"status":"ok"}'
                writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " +
                             str(len(response)).encode() + b"\r\n\r\n" + response)
            else:
                body = json.loads(await reader.readexactly(int(headers["content-length"])))
                self.tycho_calls += 1
                self.tycho_model = body.get("model")
                response = b'data: {"choices":[{"delta":{"content":"tycho"}}]}\n\ndata: [DONE]\n\n'
                writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: " +
                             str(len(response)).encode() + b"\r\n\r\n" + response)
            await writer.drain()
        finally:
            await gateway.close_writer(writer)

    async def request(self, method, path, body=None):
        reader, writer = await asyncio.open_connection(*self.address)
        payload = json.dumps(body).encode() if body is not None else b""
        writer.write((f"{method} {path} HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: {len(payload)}\r\n\r\n").encode() + payload)
        await writer.drain()
        raw = await reader.read()
        await gateway.close_writer(writer)
        head, _, rest = raw.partition(b"\r\n\r\n")
        status = int(head.split(b" ")[1])
        if b"Transfer-Encoding: chunked" in head:
            out, buf = b"", rest
            while buf:
                size, _, buf = buf.partition(b"\r\n")
                n = int(size, 16)
                if n == 0:
                    break
                out += buf[:n]; buf = buf[n + 2:]
            rest = out
        return status, head.decode(), rest

    def chat(self, model="gpt-6-astra", stream=True, effort="xhigh"):
        return {"model": model, "stream": stream, "reasoning_effort": effort, "max_tokens": 64,
                "messages": [{"role": "system", "content": "sys"}, {"role": "user", "content": "hi"}]}

    async def test_cloud_stream_is_translated_and_routed_by_model(self):
        status, head, body = await self.request("POST", "/v1/chat/completions", self.chat())
        self.assertEqual(status, 200); self.assertIn("text/event-stream", head)
        chunks = [json.loads(line[6:]) for line in body.decode().split("\n\n") if line.startswith("data: {")]
        text = "".join(c["choices"][0]["delta"].get("content", "") for c in chunks)
        self.assertEqual(text, "Hi Hal"); self.assertTrue(body.endswith(b"data: [DONE]\n\n"))
        self.assertEqual(chunks[-1]["choices"][0]["finish_reason"], "stop"); self.assertEqual(chunks[-1]["usage"]["completion_tokens"], 2)
        line, headers, sent = self.codex_calls[0]
        self.assertTrue(line.startswith("POST /backend-api/codex/responses"))
        self.assertEqual(headers["authorization"][:7], "Bearer "); self.assertEqual(headers["chatgpt-account-id"], "acct-1")
        self.assertEqual(headers["originator"], "codex_cli_rs"); self.assertEqual(headers["openai-beta"], "responses=experimental")
        self.assertEqual(sent["model"], "gpt-6-astra"); self.assertEqual(sent["reasoning"]["effort"], "xhigh"); self.assertEqual(sent["instructions"], "sys")
        self.assertEqual(self.johan_calls, 0)
        # The quota headers were recorded.
        self.assertEqual(self.brain.status()["quota"]["primary_used_percent"], 61.0)
        # A qwen-named request (sub-runs, recap, the seal) goes to the cheap tier.
        await self.request("POST", "/v1/chat/completions", self.chat(model="qwen3.8-27b", effort="medium"))
        self.assertEqual(self.codex_calls[1][2]["model"], "gpt-5.6-terra"); self.assertEqual(self.codex_calls[1][2]["reasoning"]["effort"], "medium")

    async def test_cloud_non_stream_returns_one_document(self):
        status, head, body = await self.request("POST", "/v1/chat/completions", self.chat(stream=False))
        self.assertEqual(status, 200); self.assertIn("application/json", head)
        document = json.loads(body)
        self.assertEqual(document["object"], "chat.completion"); self.assertEqual(document["choices"][0]["message"]["content"], "Hi Hal")
        self.assertEqual(document["choices"][0]["message"]["reasoning_content"], "thinking"); self.assertEqual(document["usage"]["prompt_tokens"], 7)

    async def test_health_models_and_brain_in_cloud_mode(self):
        status, _, body = await self.request("GET", "/health")
        self.assertEqual(status, 200); self.assertEqual(json.loads(body)["scope"], "brain_cloud_window")
        status, _, body = await self.request("GET", "/brain")
        self.assertEqual(json.loads(body)["mode"], "cloud")
        status, _, body = await self.request("GET", "/v1/models")
        self.assertEqual(sorted(m["id"] for m in json.loads(body)["data"]), sorted(self.brain.accepted_models()))
        status, _, body = await self.request("POST", "/v1/chat/completions", self.chat(model="gpt-9"))
        self.assertEqual(status, 400); self.assertEqual(json.loads(body)["error"]["code"], "unsupported_model")

    async def test_quota_429_flips_to_johan_and_stays(self):
        self.codex_mode = "quota"
        status, _, body = await self.request("POST", "/v1/chat/completions", self.chat())
        self.assertEqual(status, 429); self.assertEqual(json.loads(body)["error"]["code"], "usage_limit_reached")
        self.assertEqual(self.brain.mode(), "local"); self.assertEqual(self.woken, [1]); self.assertIn("usage_limit_reached", self.notices[0])
        self.codex_mode = "ok"
        status, _, body = await self.request("POST", "/v1/chat/completions", self.chat(model="gpt-6-astra"))
        self.assertEqual(status, 200); self.assertIn(b"local", body)
        self.assertEqual(self.johan_calls, 1); self.assertEqual(self.johan_model, "qwen3.8-27b")
        self.assertEqual(len(self.codex_calls), 1)
        status, _, body = await self.request("GET", "/brain")
        self.assertEqual(json.loads(body)["mode"], "local")

    async def test_expiry_flips_between_requests(self):
        await self.request("POST", "/v1/chat/completions", self.chat())
        self.now = T0 + 86400 + 1
        status, _, body = await self.request("POST", "/v1/chat/completions", self.chat())
        self.assertEqual(status, 200); self.assertIn(b"local", body); self.assertEqual(self.johan_calls, 1)
        self.assertIn("window ended", self.notices[0])

    async def test_local_observer_failure_uses_tycho_and_labels_it_honestly(self):
        self.brain.flip_local("test")
        self.busy.stale = True
        status, _, body = await self.request("POST", "/v1/chat/completions", self.chat())
        self.assertEqual(status, 200); self.assertIn(b"tycho", body)
        self.assertEqual(self.johan_calls, 0); self.assertEqual(self.tycho_calls, 1)
        self.assertEqual(self.openrouter_calls, []); self.assertEqual(self.tycho_model, "qwen3.8-27b")
        status, _, body = await self.request("GET", "/brain")
        document = json.loads(body)
        self.assertEqual(document["effective_model"], "tycho/qwen3.8-27b")
        self.assertEqual(document["local_route"], "tycho")
        status, _, body = await self.request("GET", "/health")
        self.assertEqual(json.loads(body)["scope"], "tycho_fallback_ready")
        status, _, body = await self.request("GET", "/v1/models")
        self.assertEqual(status, 200); self.assertEqual({x["id"] for x in json.loads(body)["data"]}, self.brain.accepted_models())

    async def test_advertised_local_names_roundtrip_through_real_client(self):
        import custos_brain_client as client
        self.brain.flip_local("test")
        self.busy.stale = True
        for stream in (True, False):
            for effort in ("medium", "xhigh"):
                status, _, body = await self.request("GET", "/brain")
                document = json.loads(body)
                resolved = client.resolve_model("gpt-6-astra" if stream else "gpt-5.6-terra", status=document)
                self.assertIn(resolved, self.brain.accepted_models())
                request = self.chat(model=resolved, stream=stream, effort=effort)
                request["max_tokens"] = 65536
                status, _, body = await self.request("POST", "/v1/chat/completions", request)
                self.assertEqual(status, 200, body)
                self.assertEqual(self.tycho_model, "qwen3.8-27b")
        status, _, body = await self.request("GET", "/brain")
        self.assertEqual(json.loads(body)["request_health"]["tycho"]["completed"], 4)
        self.assertEqual(self.openrouter_calls, [])

    async def test_backend_contention_waits_for_johan_instead_of_using_backup(self):
        self.brain.flip_local("test")
        self.busy.occupied = True
        request = asyncio.create_task(self.request("POST", "/v1/chat/completions", self.chat()))
        await asyncio.sleep(0.25)
        self.assertFalse(request.done()); self.assertEqual(self.openrouter_calls, []); self.assertEqual(self.tycho_calls, 0)
        self.busy.occupied = False
        status, _, body = await asyncio.wait_for(request, 2)
        self.assertEqual(status, 200); self.assertIn(b"local", body)

    async def test_unavailable_probe_sentinel_uses_pinned_mimo_with_observer_running(self):
        from unittest import mock
        import custos_busy as producer
        self.brain.flip_local("test")
        self.brain.p.pop("tycho", None)
        self.brain.p["backup"].update(model="xiaomi/mimo-v2.6-pro",
                                     provider_routing={"only": ["xiaomi"], "allow_fallbacks": False})
        # This is the sentinel the running observer publishes after the backend
        # probe exits nonzero (including a reachable host with no listener).
        producer.publish({"observed_at": 0, "foreign_busy": True, "backend_idle": False}, Path(self.directory.name))
        self.gateway.busy = gateway.BusySignal(Path(self.directory.name)/"busy.json", 5)
        real_fstat = gateway.os.fstat
        def root_stat(fd):
            actual = real_fstat(fd)
            return type("Metadata", (), {"st_uid": 0, "st_mode": actual.st_mode})()
        with mock.patch.object(gateway.os, "fstat", side_effect=root_stat):
            status, _, body = await self.request("GET", "/brain")
            self.assertEqual(json.loads(body)["effective_model"], "xiaomi/mimo-v2.6-pro")
            status, _, body = await asyncio.wait_for(self.request("POST", "/v1/chat/completions", self.chat()), 2)
        self.assertEqual(status, 200, body)
        self.assertEqual(self.johan_calls, 0)
        self.assertEqual(len(self.openrouter_calls), 1)
        self.assertEqual(self.openrouter_calls[0][2]["provider"], {"only": ["xiaomi"], "allow_fallbacks": False})

    async def test_local_connect_failure_before_response_uses_tycho(self):
        self.brain.flip_local("test")
        self.johan.close(); await self.johan.wait_closed()
        status, _, body = await self.request("POST", "/v1/chat/completions", self.chat())
        self.assertEqual(status, 200); self.assertIn(b"tycho", body)
        self.assertEqual(self.tycho_calls, 1); self.assertEqual(self.openrouter_calls, [])

    async def test_openrouter_is_third_after_johan_and_tycho_are_unavailable(self):
        self.brain.flip_local("test")
        self.busy.stale = True
        self.tycho.close(); await self.tycho.wait_closed()
        status, _, body = await self.request("POST", "/v1/chat/completions", self.chat())
        self.assertEqual(status, 200); self.assertIn(b"backup", body)
        self.assertEqual(self.johan_calls, 0); self.assertEqual(self.tycho_calls, 0)
        self.assertEqual(len(self.openrouter_calls), 1)
        _, headers, sent = self.openrouter_calls[0]
        self.assertEqual(headers["authorization"], "Bearer test-key")
        self.assertEqual(sent["model"], "deepseek/deepseek-v4.1-flash")
        self.assertNotIn("provider", sent)

    async def test_openrouter_provider_selection_survives_normal_and_streaming_gateway_requests(self):
        self.brain.flip_local("test")
        self.busy.stale = True
        self.tycho.close(); await self.tycho.wait_closed()
        self.brain.p["backup"]["provider_routing"] = {"only": ["xiaomi"], "allow_fallbacks": False}
        for streaming in (False, True):
            chat = self.chat()
            chat["stream"] = streaming
            status, _, body = await self.request("POST", "/v1/chat/completions", chat)
            self.assertEqual(status, 200)
            self.assertIn(b"backup", body)
            sent = self.openrouter_calls[-1][2]
            self.assertEqual(sent["provider"], {"only": ["xiaomi"], "allow_fallbacks": False})
            self.assertEqual(sent["stream"], streaming)
            self.assertEqual(sent["max_tokens"], chat["max_tokens"])


if __name__ == "__main__":
    unittest.main()
