#!/usr/bin/env python3
"""Operator-owned local-only Snap broker; no generative gateway/admission lock."""
import argparse
import collections
import http.server
import http.client
import json
import pathlib
import socket
import sys
import threading
import time
import urllib.error
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'runtime/headlong/bin'))
from headlong_decision_contract import (MAX_REQUEST, MAX_RESPONSE, MODEL, MODEL_SHA256,
                                        decode, encode, validate_request, validate_answers)

ENDPOINT = 'http://tycho.lan:11435/api/decide'
ALLOWED_CLIENTS = {'192.168.86.52', '127.0.0.1', '192.168.86.69'}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def request_snap(payload, timeout=1):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    req = urllib.request.Request(ENDPOINT, data=encode({**payload, 'keep_alive': -1}).encode(),
                                 headers={'Content-Type': 'application/json'})
    with opener.open(req, timeout=timeout) as response:
        raw = response.read(MAX_RESPONSE + 1)
        worker = response.headers.get('X-Snap-Worker', '')
    if len(raw) > MAX_RESPONSE:
        raise ValueError('oversized_response')
    return decode(raw), worker if worker in {'snap1', 'snap2'} else 'unknown'


def request_jev(payload, timeout=1):
    # The existing fixed-destination broker retains its credential, validation,
    # one-call admission and 60/minute limit. Bind loopback as our local source;
    # no new network client or credential permission is needed on that broker.
    conn = http.client.HTTPConnection('192.168.86.69', 18084, timeout=timeout,
                                      source_address=('127.0.0.1', 0))
    try:
        body = encode({**payload, 'model': 'jev-latest'}).encode()
        conn.request('POST', '/evaluate', body=body, headers={'Content-Type': 'application/json'})
        response = conn.getresponse()
        raw = response.read(MAX_RESPONSE + 1)
        if response.status != 200 or len(raw) > MAX_RESPONSE:
            raise ValueError('jev_broker_unavailable')
        result = decode(raw)
        if result.get('provider') != 'typesafe':
            raise ValueError('unexpected_jev_provider')
        return result
    finally:
        conn.close()


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, transport=request_snap, fallback=request_jev):
        super().__init__(address, Handler)
        self.transport = transport
        self.fallback = fallback
        self.slots = threading.BoundedSemaphore(2)
        self.connections = threading.BoundedSemaphore(12)
        self.lock = threading.Lock()
        self.calls = collections.deque()
        self.failures, self.open_until = 0, 0.
        self.counts = collections.Counter()

    def process_request(self, request, client_address):
        if not self.connections.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.connections.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.connections.release()

    def handle_error(self, *args):
        pass  # Never log bodies, headers, upstream errors or private evidence.

    def reserve(self):
        with self.lock:
            now = time.monotonic()
            while self.calls and self.calls[0] < now - 60:
                self.calls.popleft()
            if len(self.calls) >= 240:
                return 'rate_limited'
            self.calls.append(now)
            self.counts['attempted'] += 1
        return None

    def outcome(self, success):
        with self.lock:
            self.counts['succeeded' if success else 'failed'] += 1
            self.failures = 0 if success else self.failures + 1
            if self.failures >= 3:
                self.open_until = time.monotonic() + 30

    def assess(self, payload, mode):
        started = time.monotonic()
        with self.lock:
            circuit_open = time.monotonic() < self.open_until
        reason = 'tycho_circuit_open'
        if not circuit_open:
            try:
                data, worker = self.transport(payload, timeout=1 if mode == 'shadow' else 2)
                answers = validate_answers(data, payload)
                self.outcome(True)
                return {'provider': 'tycho', 'model': MODEL, 'artifact_sha256': MODEL_SHA256,
                        'worker': worker, 'answers': answers, 'state_truncated': False,
                        'fallback': False, 'latency_ms': round((time.monotonic()-started)*1000, 2)}
            except urllib.error.HTTPError as error:
                code = error.code
                error.close()
                if code in (400, 422):
                    raise ValueError('upstream_rejected_input')
                reason = 'tycho_http_' + str(code)
            except Exception:
                reason = 'tycho_unavailable_or_invalid'
            self.outcome(False)
        data = self.fallback(payload, timeout=1 if mode == 'shadow' else 26)
        answers = validate_answers(data, payload, model='jev-latest', require_complete=False)
        with self.lock:
            self.counts['jev_succeeded'] += 1
        return {'provider': 'typesafe', 'model': 'jev-latest', 'artifact_sha256': None,
                'worker': 'jev-broker', 'answers': answers, 'state_truncated': None,
                'input_policy': 'complete_request_forwarded; provider_truncation_not_reported',
                'fallback': True, 'fallback_reason': reason,
                'latency_ms': round((time.monotonic()-started)*1000, 2)}


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = 'CustosDecisions/1'
    sys_version = ''

    def setup(self):
        super().setup()
        self.connection.settimeout(3)

    def log_message(self, *args):
        pass

    def send_error(self, code, message=None, explain=None):
        self.reply(code, {'error': 'invalid_http_request'})

    def reply(self, code, value):
        raw = encode(value).encode()
        self.send_response(code)
        for k, v in {'Content-Type': 'application/json', 'Content-Length': str(len(raw)),
                     'Cache-Control': 'no-store', 'Connection': 'close'}.items():
            self.send_header(k, v)
        self.end_headers()
        self.close_connection = True
        try:
            self.wfile.write(raw)
        except (OSError, BrokenPipeError):
            pass

    def authorized(self):
        return self.client_address[0] in ALLOWED_CLIENTS and not self.headers.get('Origin')

    def do_GET(self):
        if not self.authorized():
            return self.reply(403, {'error': 'forbidden'})
        if self.path != '/health':
            return self.reply(404, {'error': 'not_found'})
        with self.server.lock:
            result = {'status': 'broker_ready', 'upstream_health': 'not_probed', 'provider': 'tycho',
                      'model': MODEL, 'artifact_sha256': MODEL_SHA256, 'workers': 2,
                      'fallback_provider': 'typesafe', 'fallback_model': 'jev-latest',
                      'circuit_open': time.monotonic() < self.server.open_until,
                      'counts': dict(self.server.counts)}
        self.reply(200, result)

    def do_POST(self):
        if not self.authorized():
            return self.reply(403, {'error': 'forbidden'})
        if self.path != '/evaluate':
            return self.reply(404, {'error': 'not_found'})
        try:
            lengths = self.headers.get_all('Content-Length') or []
            if len(lengths) != 1 or self.headers.get('Transfer-Encoding'):
                raise ValueError('invalid_length')
            size = int(lengths[0])
            if not 0 < size <= MAX_REQUEST or self.headers.get_content_type() != 'application/json':
                raise ValueError('invalid_request')
            raw = self.rfile.read(size)
            if len(raw) != size:
                raise ValueError('incomplete_body')
            payload = validate_request(decode(raw))
        except (ValueError, TypeError, RecursionError, OSError):
            return self.reply(400, {'error': 'invalid_decision_request'})
        if not self.server.slots.acquire(blocking=False):
            return self.reply(429, {'error': 'decision_busy'})
        try:
            error = self.server.reserve()
            if error:
                return self.reply(503 if error == 'circuit_open' else 429, {'error': error})
            try:
                mode = 'shadow' if self.headers.get('X-Decision-Mode') == 'shadow' else 'tool'
                result = self.server.assess(payload, mode)
                if len(encode(result).encode()) > MAX_RESPONSE:
                    raise ValueError('oversized_result')
            except ValueError as error:
                if str(error) == 'upstream_rejected_input':
                    return self.reply(422, {'error': 'upstream_rejected_input'})
                return self.reply(502, {'error': 'decision_providers_unavailable_or_invalid'})
            except Exception:
                return self.reply(502, {'error': 'decision_providers_unavailable_or_invalid'})
            return self.reply(200, result)
        finally:
            self.server.slots.release()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', default='192.168.86.69')
    parser.add_argument('--port', type=int, default=18085)
    args = parser.parse_args()
    Server((args.host, args.port)).serve_forever()


if __name__ == '__main__':
    main()
