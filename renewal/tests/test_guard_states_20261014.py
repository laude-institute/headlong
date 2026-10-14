"""Explicit guard result states for the 2026-10-14 audit fix.

Pure, focused tests for the new channel/state/receipt_namespaces/meaning
fields on Signal evaluate() responses and the non-Signal check() output.
All repo tests run through the operator's sealed hermetic Linux VM.
"""
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import custos_contact_guard as guard
import custos_actions_client as client


class GuardStateTests(unittest.TestCase):
    def setUp(self):
        self.target = 'dm:alice'
        self.route = guard.route_for(self.target)
        self.at = guard.timestamp('2026-10-07T12:00:00+00:00')
        self.proof = {'phase': 'submitted', 'receipt': {'timestamp': self.at * 1000,
                                                        'results': [{'type': 'SUCCESS'}]}}

    def row(self, **extra):
        row = {'from': 'custos', 'to': self.route, 'ts': guard.iso(self.at - 3 * 3600),
               'request_id': 'one', 'delivered_by': 'custos-actions'}
        row.update(extra)
        return row

    def decide(self, rows=None, proof=None, hours=12, cross=True):
        proof = self.proof if proof is None else proof
        return guard.evaluate(rows or [self.row()], self.target, self.route, hours, cross,
                              lambda ref: proof, self.at)

    def test_open_state_with_null_resume_at(self):
        reply = {'from': self.route, 'to': 'custos', 'ts': guard.iso(self.at), 'content': 'hi'}
        result = self.decide(rows=[self.row(), reply])
        self.assertTrue(result['ok'])
        self.assertIsNone(result['resume_at'])
        self.assertEqual(result['channel'], 'signal')
        self.assertEqual(result['receipt_namespaces'], ['action', 'outbox'])
        self.assertEqual(result['state'], 'open')
        self.assertIn('ok', result['meaning'])
        self.assertIn('resume_at', result['meaning'])
        self.assertIn('not a block', result['meaning'])

    def test_open_state_after_eligible_reply(self):
        reply = {'from': self.route, 'to': 'custos', 'ts': guard.iso(self.at), 'content': 'hi'}
        result = self.decide(rows=[self.row(), reply], cross=False)
        self.assertEqual(result['mode'], 'mind')
        self.assertTrue(result['ok'])
        self.assertEqual(result['state'], 'open')
        self.assertIsNone(result['resume_at'])
        self.assertEqual(result['channel'], 'signal')
        self.assertEqual(result['receipt_namespaces'], ['action', 'outbox'])

    def test_zero_hour_window_is_open_with_null_resume_at(self):
        result = self.decide(hours=0)
        self.assertTrue(result['ok'])
        self.assertEqual(result['state'], 'open')
        self.assertIsNone(result['resume_at'])

    def test_cooldown_state_carries_deadline(self):
        proof = {'phase': 'submitted', 'receipt': {'timestamp': (self.at - 3 * 3600) * 1000,
                                                   'results': [{'type': 'SUCCESS'}]}}
        result = self.decide(proof=proof)
        self.assertFalse(result['ok'])
        self.assertEqual(result['reason'], 'cooldown')
        self.assertEqual(result['state'], 'cooldown')
        self.assertEqual(result['resume_at'], '2026-10-07T21:00:00+00:00')
        self.assertEqual(result['channel'], 'signal')
        self.assertEqual(result['receipt_namespaces'], ['action', 'outbox'])
        self.assertIn('ok', result['meaning'])
        self.assertIn('cooldown deadline', result['meaning'])

    def test_unresolved_state_with_null_resume_at(self):
        result = self.decide(proof={'phase': 'queued', 'record_found': True, 'receipt': None})
        self.assertFalse(result['ok'])
        self.assertEqual(result['reason'], 'delivery-unresolved')
        self.assertEqual(result['state'], 'unresolved')
        self.assertIsNone(result['resume_at'])
        self.assertEqual(result['channel'], 'signal')
        self.assertEqual(result['receipt_namespaces'], ['action', 'outbox'])
        self.assertIn('not a block on its own', result['meaning'])

    def test_non_signal_check_is_not_applicable(self):
        with tempfile.TemporaryDirectory() as temp:
            (Path(temp) / 'social-policy.json').write_text('{}')
            def broker(payload, timeout=3):
                if payload['action'] == 'signal-contacts':
                    return 200, {'ok': True, 'contacts': [{'label': 'Hal', 'target': self.target}]}
                self.fail(payload)
            with patch.dict(os.environ, {'IDENTITY_DIR': temp, 'TRAJ_ID': 'fixture'}), \
                    patch.object(client, 'call', side_effect=broker):
                result = guard.check('someone-else', hours=12, cross=False)
        self.assertFalse(result['applicable'])
        self.assertTrue(result['ok'])
        self.assertEqual(result['channel'], 'native')
        self.assertEqual(result['state'], 'not-applicable')
        self.assertEqual(result['receipt_namespaces'], [])
        self.assertIn('no Signal send or receipt', result['meaning'])

    def test_signal_check_reports_open_state(self):
        with tempfile.TemporaryDirectory() as temp:
            (Path(temp) / 'social-policy.json').write_text('{}')
            def broker(payload, timeout=3):
                if payload['action'] == 'signal-contacts':
                    return 200, {'ok': True, 'contacts': [{'label': 'Hal', 'target': self.target}]}
                if payload['action'] == 'delivery-status-batch':
                    return 200, {'ok': True, 'results': {}}
                if payload['action'] == 'signal-contact-outbox':
                    return 200, {'ok': True, 'outgoing': []}
                self.fail(payload)
            with patch.dict(os.environ, {'IDENTITY_DIR': temp, 'TRAJ_ID': 'fixture'}), \
                    patch.object(client, 'call', side_effect=broker), \
                    patch.object(guard, 'indexed_rows', side_effect=lambda path: []), \
                    patch.object(guard.subprocess, 'run', return_value=Mock(stdout='/fixture/trajectory')):
                result = guard.check('Hal', hours=12, cross=False)
        self.assertTrue(result['applicable'])
        self.assertTrue(result['ok'])
        self.assertEqual(result['channel'], 'signal')
        self.assertEqual(result['state'], 'open')
        self.assertEqual(result['receipt_namespaces'], ['action', 'outbox'])
        self.assertIsNone(result['resume_at'])


if __name__ == '__main__':
    unittest.main()
