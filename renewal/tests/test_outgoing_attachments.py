import base64
import copy
import io
import http.client
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import custos_attachments as att
import custos_actions as ca
import custos_actions_client as client
import custos_signal as cs
import test_actions
from test_signal import POLICY, HAL, BOT, STRANGER, envelope


def file(name='image.png', raw=b'opaque image bytes', mime='image/png'):
    return {'filename': name, 'content_type': mime, 'data': base64.b64encode(raw).decode()}


class FilesTests(unittest.TestCase):
    def test_filename_mime_bytes_and_no_paths(self):
        f = file('report;résumé.pdf', b'%PDF-fixture', 'application/pdf')
        checked = att.validate([f])
        self.assertEqual(checked[0]['size'], 12)
        self.assertNotIn('data', att.metadata(checked)[0])
        self.assertTrue(att.data_uris(checked)[0].startswith('data:application/pdf;filename=report%3Br%C3%A9sum%C3%A9.pdf;base64,'))
        for bad in ['../secret', '/etc/passwd', 'a\\b', 'bad\nname', '..', '']:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                att.validate([{**f, 'filename': bad}])
        for change in [{'path': '/etc/passwd'}, {'data': 'https://example.com'}, {'data': '!!!!'},
                       {'data': ''}, {'content_type': 'image/png;filename=x'}, {'data': 7}]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                att.validate([{**f, **change}])
        for bad in [[], [f] * 5, '/etc/passwd', ['file:///etc/passwd']]:
            with self.assertRaises(ValueError): att.validate(bad)

    def test_total_size_and_guest_regular_file_snapshot(self):
        with patch.object(att, 'MAX_BYTES', 5):
            self.assertEqual(att.validate([file(raw=b'12345')])[0]['size'], 5)
            for files in [[file(raw=b'123456')], [file(raw=b'123'), file(raw=b'456')]]:
                with self.assertRaises(ValueError): att.validate(files)
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'report.txt'; path.write_bytes(b'original')
            files = att.read_files([path]); path.write_bytes(b'changed')
            self.assertEqual(base64.b64decode(files[0]['data']), b'original')
            self.assertEqual(files[0]['content_type'], 'text/plain')
            fifo = Path(root) / 'fifo'; os.mkfifo(fifo)
            with self.assertRaises(ValueError): att.read_files([fifo])
            with self.assertRaises((ValueError, OSError)): att.read_files([root])
            with self.assertRaises(ValueError): att.read_files([path] * 5)


class AttachmentActionsTests(unittest.TestCase):
    setUp = test_actions.ActionsTests.setUp
    status = test_actions.ActionsTests.status

    def test_snapshot_receipt_cleanup_and_replay_after_cleanup(self):
        p = {**self.p, 'message': '', 'attachments': [file(), file('report.pdf', b'%PDF-document', 'application/pdf')]}
        self.channel.handle(p)
        with ca.connect(self.state) as db:
            self.assertNotIn('data', json.loads(db.execute('SELECT payload FROM actions').fetchone()[0])['attachments'][0])
        # A new bridge instance recovers the exact snapshot.
        bridge = cs.Bridge(self.policy, self.bridge.spool, self.state); bridge.rpc = self.bridge.rpc
        with patch.object(cs, 'paused', return_value=False): bridge.proactive()
        params = self.bridge.rpc.call.call_args.args[1]
        self.assertEqual(params['message'], '')
        self.assertEqual(params['recipient'], [HAL])
        self.assertEqual(params['attachments'], att.data_uris(att.validate(p['attachments'])))
        self.assertEqual(self.status()['phase'], 'submitted')
        with ca.connect(self.state) as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM attachments').fetchone()[0], 0)
        self.assertEqual(self.channel.handle(p)['phase'], 'submitted')
        with self.assertRaises(ValueError):
            self.channel.handle({**p, 'attachments': [file(raw=b'changed')]})
        with patch.object(cs, 'paused', return_value=False): bridge.proactive()
        self.assertEqual(self.bridge.rpc.call.call_count, 1)

    def test_quota_invalid_upload_and_missing_snapshot_never_send_caption_alone(self):
        p = {**self.p, 'attachments': [file()]}
        with patch.object(att, 'MAX_QUEUED_BYTES', 1), self.assertRaises(ValueError): self.channel.handle(p)
        self.assertFalse(self.status()['ok'])
        with self.assertRaises(ValueError): self.channel.handle({**p, 'attachments': ['/etc/passwd']})
        self.channel.handle(p)
        with ca.connect(self.state) as db: db.execute('DELETE FROM attachments')
        with patch.object(cs, 'paused', return_value=False): self.bridge.proactive()
        self.assertEqual(self.status()['phase'], 'blocked')
        self.bridge.rpc.call.assert_not_called()

    def test_timeout_retains_bytes_and_never_retries(self):
        p = {**self.p, 'attachments': [file()]}; self.channel.handle(p)
        self.bridge.rpc.call.side_effect = TimeoutError()
        with patch.object(cs, 'paused', return_value=False), self.assertRaises(TimeoutError): self.bridge.proactive()
        self.assertEqual(self.status()['phase'], 'uncertain')
        with ca.connect(self.state) as db: self.assertEqual(db.execute('SELECT COUNT(*) FROM attachments').fetchone()[0], 1)
        self.assertEqual(self.channel.handle(p)['phase'], 'uncertain')
        with patch.object(cs, 'paused', return_value=False): self.bridge.proactive()
        self.assertEqual(self.bridge.rpc.call.call_count, 1)

    def test_group_policy_pause_and_removed_contact(self):
        p = {**self.p, 'target': 'Group', 'attachments': [file()]}; self.channel.handle(p)
        self.bridge.rpc.call.return_value = [{'id':'agreed-group','isMember':True,'members':[BOT, HAL, STRANGER]}]
        with patch.object(cs, 'paused', return_value=False): self.bridge.proactive()
        self.assertEqual(self.status()['phase'], 'blocked')
        self.assertEqual(self.bridge.rpc.call.call_args.args[0], 'listGroups')
        p = {**self.p, 'request_id': 'two', 'attachments': [file()]}; self.channel.handle(p)
        self.bridge.rpc.reset_mock()
        with patch.object(cs, 'paused', return_value=True): self.bridge.proactive()
        self.bridge.rpc.call.assert_not_called()
        policy = copy.deepcopy(POLICY); del policy['people'][HAL]; self.policy.write_text(json.dumps(policy))
        with patch.object(cs, 'paused', return_value=False): self.bridge.proactive()
        self.bridge.rpc.call.assert_not_called()

    def test_quoted_reply_uses_host_spool_and_rejects_cross_chat_deleted_or_ambient(self):
        item = cs.classify(envelope(message='Please send the picture'), POLICY)
        self.bridge.spool.receive(item)
        db = self.bridge.spool.db
        with db: db.execute("UPDATE inbox SET phase='queued',mode='normal'")
        p = {**self.p, 'attachments': [file()], 'reply_to': item['request_id']}
        for change in [{'target': 'Group'}, {'reply_to':'missing'}]:
            with self.assertRaises(ValueError): self.bridge.attachment_reply({**p, 'target':'dm:'+HAL, **change})
        for mode in ['context_only', 'digest', 'emoji_only']:
            with db: db.execute('UPDATE inbox SET mode=?', (mode,))
            with self.assertRaises(ValueError): self.bridge.attachment_reply({**p, 'target':'dm:'+HAL})
        with db: db.execute("UPDATE inbox SET mode='normal'")
        self.channel.handle(p)
        with patch.object(cs, 'paused', return_value=False): self.bridge.proactive()
        params = self.bridge.rpc.call.call_args.args[1]
        self.assertEqual(params['quoteAuthor'], HAL)
        self.assertEqual(params['quoteTimestamp'], item['timestamp'])
        self.assertEqual(params['quoteMessage'], 'Please send the picture')
        with db: db.execute("UPDATE inbox SET phase='cancelled'")
        with self.assertRaises(ValueError): self.bridge.attachment_reply({**p, 'target':'dm:'+HAL})


class ClientTests(unittest.TestCase):
    def test_cli_attaches_bytes_and_records_only_metadata(self):
        with tempfile.TemporaryDirectory() as root:
            env = patch.dict(os.environ, {'IDENTITY_DIR': root}); env.start(); self.addCleanup(env.stop)
            path = Path(root) / 'report.txt'; path.write_text('file contents')
            body = json.dumps({'request_id':'file-one','target':'dm:'+HAL,'message':'Here it is'})
            with patch.object(sys, 'argv', ['custos-actions','signal-send','--attach',str(path)]), \
                    patch.object(sys, 'stdin', io.TextIOWrapper(io.BytesIO(body.encode()))), \
                    patch.object(sys, 'stdout', io.StringIO()), patch.object(client, 'guard'), \
                    patch.object(client, 'call', return_value=(200, {'ok':True,'phase':'queued'})) as call, \
                    patch.object(client, 'record') as record:
                self.assertEqual(client.main(), 0)
            payload = call.call_args.args[0]
            self.assertEqual(base64.b64decode(payload['attachments'][0]['data']), b'file contents')
            self.assertNotIn(str(path), json.dumps(payload))
            with patch.dict(os.environ, {'ROOT_TRAJ_ID':'root'}), patch.object(client.subprocess, 'run') as run:
                client.record(*record.call_args.args)
            step = json.loads(run.call_args.kwargs['input'])
            self.assertEqual(step['attachments'][0]['filename'], 'report.txt')
            self.assertNotIn('data', step['attachments'][0])
            self.assertEqual(step['delivered_by'], 'custos-actions')

    def test_reply_prefix_requires_unique_receipt_and_correct_route(self):
        with tempfile.TemporaryDirectory() as root, patch.dict(os.environ, {'IDENTITY_DIR':root}):
            state = Path(root)/'.state'/'transport'; state.mkdir(parents=True)
            r = {'step_id':'abcdef01-1234','phase':'queued','original':{'request_id':'signal-one','sender':'signal-route'}}
            (state/'one.json').write_text(json.dumps(r))
            self.assertEqual(client.resolve_reply('abcdef01','signal-route'), ('signal-one','abcdef01-1234'))
            with self.assertRaises(ValueError): client.resolve_reply('abcdef01','wrong-route')
            (state/'two.json').write_text(json.dumps({**r,'step_id':'abcdef01-5678'}))
            with self.assertRaises(ValueError): client.resolve_reply('abcdef01','signal-route')


class BodyLimitTests(unittest.TestCase):
    def request(self, payload, path='/v1/actions', address='192.168.86.52', length=None):
        raw = json.dumps(payload).encode()
        handler = object.__new__(ca.Handler)
        handler.client_address = (address, 123)
        handler.path = path
        handler.headers = http.client.parse_headers(io.BytesIO(
            ('Content-Length: %s\r\nContent-Type: application/json\r\n\r\n' %
             (len(raw) if length is None else length)).encode()))
        handler.rfile, handler.wfile = io.BytesIO(raw), io.BytesIO()
        handler.send_response, handler.send_header, handler.end_headers = Mock(), Mock(), Mock()
        handler.server = Mock()
        handler.server.channel.handle.return_value = {'ok':True, 'phase':'queued'}
        handler.do_POST()
        return handler.send_response.call_args.args[0], handler

    def test_large_files_only_on_actions_and_authorized_client(self):
        payload = {'action':'signal-send','request_id':'upload','target':'Hal','message':'caption',
                   'attachments':[file(raw=b'x'*40000)]}
        code, handler = self.request(payload)
        self.assertEqual(code, 200)
        self.assertEqual(handler.server.channel.handle.call_args.args[0], payload)
        for opts in [{'path':'/v1/harness'}, {'address':'127.0.0.1'}, {'length':att.MAX_WIRE+1}]:
            code, handler = self.request(payload, **opts)
            self.assertIn(code, (400,403))
            handler.server.channel.handle.assert_not_called()
        code, handler = self.request({**payload,'action':'automata-deploy'})
        self.assertEqual(code,400); handler.server.channel.handle.assert_not_called()

    def test_upload_concurrency_bound_releases_slot_after_error(self):
        payload = {'action':'signal-send','attachments':[file(raw=b'x'*40000)]}
        with ca.UPLOAD_SLOT:
            code, handler = self.request(payload)
            self.assertEqual(code,503); handler.server.channel.handle.assert_not_called()
        code, handler = self.request(payload, length=60000)  # incomplete body after acquiring slot
        self.assertEqual(code,400)
        self.assertTrue(ca.UPLOAD_SLOT.acquire(blocking=False)); ca.UPLOAD_SLOT.release()


if __name__ == '__main__': unittest.main()
