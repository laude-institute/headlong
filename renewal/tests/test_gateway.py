"""Run by integration owner: python3 -m unittest discover -s renewal/tests -p test_gateway.py.
All networking here uses disposable loopback servers; no real model requests.
"""
import asyncio
import contextlib
import datetime as dt
import json
from pathlib import Path
import tempfile
import unittest
import sys
from zoneinfo import ZoneInfo
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import custos_gateway as gateway
import custos_backend_probe as probe
import custos_busy as producer


def epoch(local):
    return dt.datetime.fromisoformat(local).replace(tzinfo=ZoneInfo("America/Denver")).timestamp()


class PayloadTests(unittest.TestCase):
    def test_media_redirect_inputs_aliases_and_unbounded_output_rejected(self):
        base = {"model": gateway.MODEL, "messages": [{"role": "user", "content": "hello"}]}
        changes = [{"model": "hosted/fallback"}, {"max_tokens": 32769},
                   {"messages": [{"role": "user", "content": [{"type": "image_url", "image_url": {"url": "http://127.0.0.1/secret"}}]}]},
                   {"extra_body": {"base_url": "http://127.0.0.1"}},
                   {"messages": [{"role": "user", "content": "x"}] * 129}]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(gateway.Denied):
                gateway.payload(json.dumps(base | change).encode(), 32768)
        explicit = json.loads(gateway.payload(json.dumps(base | {"reasoning_effort": "xhigh"}).encode(), 32768))
        self.assertEqual(explicit["reasoning_effort"], "xhigh")

    def test_xhigh_default_and_expanded_reasoning_limits(self):
        policy = gateway.load_policy(str(Path(__file__).resolve().parents[1] / "gateway-policy.json"))
        self.assertEqual(policy["request_seconds"], 600)
        self.assertEqual(policy["max_tokens"], 65536)
        self.assertEqual(policy["max_response_bytes"], 33554432)
        value = json.loads(gateway.payload(json.dumps({"model":gateway.MODEL,"messages":[{"role":"user","content":"hello"}]}).encode(), policy["max_tokens"]))
        self.assertEqual(value["reasoning_effort"], "xhigh")
        self.assertEqual(value["max_tokens"], 65536)

    def test_duplicate_keys_and_deep_json_are_rejected(self):
        for raw in (b'{"model":"x","model":"qwen3.8-27b"}', b"[" * 65 + b"0" + b"]" * 65):
            with self.assertRaises(gateway.Denied):
                gateway.payload(raw, 32768)


class SignalTests(unittest.TestCase):
    def test_stale_missing_foreign_and_busy_backend_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "busy.json"
            signal = gateway.BusySignal(path, 5)
            with self.assertRaises(gateway.Denied):
                signal.check(100)
            for value in ({"observed_at": 90, "foreign_busy": False, "backend_idle": True},
                          {"observed_at": 100, "foreign_busy": True, "backend_idle": False},
                          {"observed_at": 100, "foreign_busy": False, "backend_idle": False}):
                producer.publish(value, Path(directory))
                # Non-root developer environments can exercise trusted-file parsing
                # without changing system ownership or requiring privilege.
                real_fstat = gateway.os.fstat
                def root_stat(fd):
                    actual = real_fstat(fd)
                    return type("Metadata", (), {"st_uid": 0, "st_mode": actual.st_mode})()
                with mock.patch.object(gateway.os, "fstat", side_effect=root_stat), self.assertRaises(gateway.Denied):
                    signal.check(100)

    def test_proc_socket_decoding_distinguishes_own_and_foreign_peers(self):
        self.assertEqual(probe.address("2C56A8C0", False), "192.168.86.44")
        self.assertEqual(probe.address("0100007F", False), "127.0.0.1")
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(probe.socket, "gethostname", return_value="johan"):
            path = Path(directory) / "tcp"
            path.write_text("header\n 0: 00000000:1F90 2C56A8C0:A001 01 rest\n")
            self.assertEqual(probe.snapshot((str(path),)), {"foreign_busy": False, "backend_idle": False})
            path.write_text("header\n 0: 00000000:1F90 0100007F:A001 01 rest\n")
            self.assertEqual(probe.snapshot((str(path),)), {"foreign_busy": True, "backend_idle": False})


class MutableBusy:
    foreign = False
    stale = False

    def check(self, now, admission=True):
        if self.stale:
            raise gateway.Denied(503, "busy_observation_unavailable", 30)
        if self.foreign:
            raise gateway.Denied(503, "backend_reserved_for_other_users", 30)


class WireTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.now = epoch("2026-09-07T12:00:00")
        self.started, self.disconnected = asyncio.Event(), asyncio.Event()
        self.release_response = asyncio.Event()
        self.backend_tasks = set()
        self.mode, self.calls = "sse", 0
        self.sse = 'data: {"choices":[{"delta":{"content":"héllo"}}]}\n\ndata: {"choices":[],"usage":{"completion_tokens":2}}\n\ndata: [DONE]\n\n'.encode()
        self.backend = await asyncio.start_server(self.backend_handle, "127.0.0.1", 0)
        upstream = self.backend.sockets[0].getsockname()[:2]
        policy = gateway.load_policy(Path(__file__).resolve().parents[1] / "gateway-policy.json")
        policy.update(allowed_clients=["127.0.0.1"],
                      pause_file=str(Path(self.directory.name) / "paused"))
        self.busy = MutableBusy()
        self.gateway = gateway.Gateway(policy, busy=self.busy, clock=lambda: self.now, upstream=upstream)
        self.server = await asyncio.start_server(self.gateway.accept, "127.0.0.1", 0, limit=policy["max_header_bytes"])
        self.address = self.server.sockets[0].getsockname()[:2]

    async def asyncTearDown(self):
        self.server.close()
        self.backend.close()
        await self.server.wait_closed()
        await self.backend.wait_closed()
        tasks = list(self.gateway.tasks | self.backend_tasks)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        self.directory.cleanup()

    async def backend_handle(self, reader, writer):
        task = asyncio.current_task()
        self.backend_tasks.add(task)
        try:
            _, headers = await gateway.read_headers(reader, 16384)
            await reader.readexactly(int(headers["content-length"]))
            self.calls += 1
            self.started.set()
            if self.mode == "gated_sse":
                await self.release_response.wait()
            if self.mode == "stream_wait":
                chunk = b'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n'
                writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
                writer.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                await writer.drain()
                await reader.read()
                self.disconnected.set()
                return
            if self.mode == "wait":
                await reader.read()
                self.disconnected.set()
                return
            if self.mode == "redirect":
                writer.write(b"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1/secret\r\nContent-Length: 0\r\n\r\n")
            elif self.mode == "busy":
                body = b'{"error":{"message":"busy"}}'
                writer.write(b"HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nRetry-After: 91\r\nContent-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
            else:
                writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
                for chunk in (self.sse[:13], self.sse[13:]):
                    writer.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                writer.write(b"0\r\n\r\n")
            await writer.drain()
        except gateway.Denied:
            # Deadline cancellation may close a just-connected fixture socket
            # before its request headers arrive.
            pass
        finally:
            await gateway.close_writer(writer)
            self.backend_tasks.discard(task)

    async def connect(self, path="/v1/chat/completions", method="POST", raw=None):
        reader, writer = await asyncio.open_connection(*self.address)
        body = json.dumps({"model": gateway.MODEL, "messages": [{"role": "user", "content": "hello"}], "stream": True}).encode() if method == "POST" else b""
        writer.write(raw or (f"{method} {path} HTTP/1.1\r\nHost: gateway\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n".encode() + body))
        await writer.drain()
        return reader, writer

    async def test_valid_utf8_request_is_not_expanded_past_the_admission_limit(self):
        body = json.dumps({
            "model": gateway.MODEL,
            "messages": [{"role": "user", "content": "界" * 24000}],
            "stream": True,
        }, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        request = (f"POST /v1/chat/completions HTTP/1.1\r\nHost: gateway\r\n"
                   f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n").encode() + body
        status, _, response = await self.response(raw=request)
        self.assertEqual(status, 200)
        self.assertIn(b"[DONE]", response)

    async def test_health_has_no_usage_quota_and_never_opens_historical_ledger(self):
        old = Path(self.directory.name) / "quota.sqlite3"
        old.write_bytes(b"historical exhausted quota - preserve verbatim")
        for _ in range(3):
            status, _, body = await self.response("/health", "GET")
            self.assertEqual(status, 200)
            self.assertIsNone(json.loads(body)["usage_quota"])
        self.assertEqual(old.read_bytes(), b"historical exhausted quota - preserve verbatim")
        self.assertFalse(hasattr(self.gateway, "ledger"))

    async def response(self, path="/v1/chat/completions", method="POST", raw=None, header_timeout=2):
        reader, writer = await self.connect(path, method, raw)
        try:
            line, headers = await asyncio.wait_for(gateway.read_headers(reader, 16384), header_timeout)
            body = b""
            if headers.get("transfer-encoding") == "chunked":
                while True:
                    count = int((await reader.readline()).strip(), 16)
                    if not count:
                        await reader.readexactly(2)
                        break
                    body += await reader.readexactly(count)
                    self.assertEqual(await reader.readexactly(2), b"\r\n")
            else:
                body = await reader.readexactly(int(headers.get("content-length", 0)))
            return int(line.split()[1]), headers, body
        finally:
            await gateway.close_writer(writer)

    async def test_sse_content_usage_and_done_are_byte_preserved(self):
        status, headers, body = await self.response()
        self.assertEqual(status, 200)
        self.assertEqual(headers["content-type"], "text/event-stream")
        self.assertEqual(body, self.sse)

    async def test_interrupted_sse_never_fabricates_completion_or_clean_ending(self):
        self.mode = "stream_wait"
        reader, writer = await self.connect()
        line, _ = await asyncio.wait_for(gateway.read_headers(reader, 16384), 2)
        self.assertIn("200", line)
        count = int((await reader.readline()).strip(), 16)
        first = await reader.readexactly(count + 2)
        Path(self.gateway.p["pause_file"]).touch()
        raw = first + await asyncio.wait_for(reader.read(), 2)
        self.assertIn(b"partial", raw)
        self.assertNotIn(b"[DONE]", raw)
        self.assertFalse(raw.endswith(b"0\r\n\r\n"))
        await asyncio.wait_for(self.disconnected.wait(), 2)
        await gateway.close_writer(writer)

    async def test_many_calls_across_midnight_have_no_accumulated_limit(self):
        for i in range(45):
            self.now = epoch("2026-09-07T23:00:00") + i * 180
            self.assertEqual((await self.response())[0], 200)
        self.assertEqual(self.calls, 45)

    async def test_foreign_arrival_and_stale_probe_do_not_preempt_custos(self):
        self.mode = "gated_sse"
        response = asyncio.create_task(self.response())
        await asyncio.wait_for(self.started.wait(), 2)
        self.busy.foreign = self.busy.stale = True
        await asyncio.sleep(0.2)
        self.assertFalse(response.done())
        self.release_response.set()
        status, _, body = await asyncio.wait_for(response, 2)
        self.assertEqual((status, body), (200, self.sse))

    async def test_evening_midnight_and_early_morning_admit_every_surface(self):
        for local in ("2026-09-07T20:59:59", "2026-09-07T21:00:00",
                      "2026-09-08T00:00:00", "2026-09-08T05:59:59"):
            self.now = epoch(local)
            for path, method in (("/v1/chat/completions", "POST"), ("/v1/models", "GET"),
                                 ("/v1/models/" + gateway.MODEL, "GET"), ("/health", "GET")):
                with self.subTest(local=local, path=path):
                    status, _, body = await self.response(path, method)
                    self.assertEqual(status, 200)
                    if path == "/health":
                        self.assertEqual(json.loads(body)["status"], "ok")
                    else:
                        self.assertEqual(body, self.sse)
        self.assertEqual(self.calls, 12)

    async def test_inflight_response_completes_across_evening_boundary(self):
        self.now = epoch("2026-09-07T20:59:57")
        self.mode = "gated_sse"
        response = asyncio.create_task(self.response())
        try:
            await asyncio.wait_for(self.started.wait(), 2)
            self.now = epoch("2026-09-07T21:00:00")
            observed = asyncio.Event()
            def clock():
                observed.set()
                return self.now
            self.gateway.clock = clock
            await asyncio.wait_for(observed.wait(), 2)
            self.release_response.set()
            status, _, body = await asyncio.wait_for(response, 2)
            self.assertEqual(status, 200)
            self.assertEqual(body, self.sse)
        finally:
            response.cancel()
            await asyncio.gather(response, return_exceptions=True)

    async def test_operator_pause_still_blocks_every_surface_at_night(self):
        self.now = epoch("2026-09-07T21:00:00")
        Path(self.gateway.p["pause_file"]).touch()
        for path, method in (("/v1/chat/completions", "POST"), ("/v1/models", "GET"),
                             ("/v1/models/" + gateway.MODEL, "GET"), ("/health", "GET")):
            status, headers, body = await self.response(path, method)
            self.assertEqual(status, 503)
            self.assertEqual(json.loads(body)["error"]["code"], "operator_paused")
            self.assertEqual(headers["retry-after"], "300")
        self.assertEqual(self.calls, 0)

    async def test_paths_methods_framing_and_size_do_not_reach_backend(self):
        for path in ("http://127.0.0.1/v1/models", "/v1/models?url=http://localhost", "/v1/responses", "/v1/models/other", "/v1/%63hat/completions"):
            status, _, _ = await self.response(path, "GET")
            self.assertEqual(status, 404)
        for raw, expected in ((b"POST /v1/chat/completions HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", 400),
                              (b"POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 4194305\r\n\r\n", 413),
                              (b"POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n", 400)):
            status, _, _ = await self.response(raw=raw)
            self.assertEqual(status, expected)
        self.assertEqual((await self.response("/v1/models", "POST"))[0], 405)
        self.assertEqual(self.calls, 0)

    async def test_upstream_redirect_is_not_followed(self):
        self.mode = "redirect"
        status, _, body = await self.response()
        self.assertEqual(status, 502)
        self.assertIn(b"upstream_redirect", body)
        self.assertEqual(self.calls, 1)

    async def test_upstream_retry_after_is_preserved_without_retry(self):
        self.mode = "busy"
        status, headers, body = await self.response()
        self.assertEqual((status, headers["retry-after"]), (503, "91"))
        self.assertEqual(json.loads(body)["error"]["message"], "busy")
        self.assertEqual(self.calls, 1)

    async def test_client_cancel_closes_upstream_and_releases_slot(self):
        self.mode = "wait"
        reader, writer = await self.connect()
        await asyncio.wait_for(self.started.wait(), 2)
        await gateway.close_writer(writer)
        await asyncio.wait_for(self.disconnected.wait(), 2)
        for _ in range(100):
            if not self.gateway.inflight:
                break
            await asyncio.sleep(0.01)
        self.mode = "sse"
        self.assertEqual((await self.response())[0], 200)
        self.assertEqual(self.calls, 2)

    async def test_runtime_limit_includes_waiting(self):
        self.mode = "wait"
        # Exercise a one-second real monotonic timeout.
        self.gateway.p["request_seconds"] = 1
        reader, writer = await self.connect()
        await asyncio.wait_for(self.started.wait(), 2)
        # The one-second request deadline precedes bounded socket cancellation
        # (close_writer itself allows one second). A two-second reader raced
        # that cleanup in the VM; do not confuse it with the asserted 503 code.
        status, _, body = await self.response(header_timeout=4)
        self.assertEqual(status, 503)
        self.assertIn(b"request_walltime_limit", body)
        await asyncio.wait_for(self.disconnected.wait(), 2)
        line, _ = await gateway.read_headers(reader, 16384)
        self.assertIn("503", line)
        await gateway.close_writer(writer)

    async def test_concurrent_requests_wait_fifo_and_never_overlap(self):
        self.mode = "gated_sse"
        first = asyncio.create_task(self.response())
        await self.started.wait()
        second = asyncio.create_task(self.response())
        await asyncio.sleep(0.05)
        third = asyncio.create_task(self.response())
        await asyncio.sleep(0.05)
        self.assertEqual(self.calls, 1)
        self.assertFalse(second.done())
        self.assertFalse(third.done())
        self.release_response.set()
        results = await asyncio.gather(first, second, third)
        self.assertEqual([r[0] for r in results], [200, 200, 200])
        self.assertEqual(self.calls, 3)
        self.assertFalse(self.gateway.slot.locked())

    async def test_busy_snapshot_waits_and_pause_cancels_queue(self):
        def busy(now, admission=True):
            raise gateway.Denied(503, "backend_busy_or_unavailable", 30)
        self.busy.check = busy
        response = asyncio.create_task(self.response())
        await asyncio.sleep(0.1)
        self.assertEqual(self.calls, 0)
        self.assertFalse(response.done())
        Path(self.gateway.p["pause_file"]).touch()
        status, _, body = await response
        self.assertEqual(status, 503)
        self.assertIn(b"operator_paused", body)
        self.assertEqual(self.calls, 0)

    async def test_waiting_disconnect_never_reaches_backend(self):
        self.mode = "gated_sse"
        first = asyncio.create_task(self.response())
        await self.started.wait()
        _, writer = await self.connect()
        await asyncio.sleep(0.05)
        await gateway.close_writer(writer)
        await asyncio.sleep(0.15)
        self.release_response.set()
        self.assertEqual((await first)[0], 200)
        self.assertEqual(self.calls, 1)


if __name__ == "__main__":
    unittest.main()
