"""Incident replays with real native tools in disposable identities, fake host IO."""
import datetime as dt
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch, Mock
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import custos_actions_client as client
import custos_signal_drafts as drafts
import custos_memory as cm
import custos_dream as dream
import custos_news_delivery as news
import test_delivery_honesty as chat_tests
import test_memory as memory_tests


class ReplyTests(chat_tests.ChatFixture):
    def test_origin_request_id_uses_same_bridge_path_as_native_step(self):
        request = self.inbound(self.bob, chat_tests.UUID_B)
        log = self.fake_actions([{'target': self.contact, 'label': 'Bob'}])
        result = self.chat('reply', '--follow-up', '--reply-to', request, self.bob, 'Recorded your recipes')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(log.exists(), 'explicit reply must never become a proactive action')
        self.assertEqual(self.outgoing()[0]['reply_to'], chat_tests.UUID_B)
        self.assertIn('submission is pending', result.stderr)

    def test_wrong_room_and_unknown_id_never_fall_back_to_proactive(self):
        self.inbound(self.bob, chat_tests.UUID_B)
        request = self.inbound(self.alice, chat_tests.UUID_A)
        log = self.fake_actions([{'target': self.contact, 'label': 'Bob'}])
        for ref in [request, chat_tests.UUID_A, 'signal:unknown']:
            result = self.chat('reply', '--follow-up', '--reply-to', ref, self.bob, 'A requested result')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('no proactive fallback', result.stderr)
        self.assertFalse(log.exists()); self.assertEqual(self.outgoing(), [])

    def test_request_id_is_canonical_before_duplicate_guard(self):
        request = self.inbound(self.bob, chat_tests.UUID_B)
        self.assertEqual(self.chat('reply', '--reply-to', chat_tests.UUID_B, self.bob, 'one').returncode, 0)
        result = self.chat('reply', '--reply-to', request, self.bob, 'two')
        self.assertEqual(result.returncode, 0); self.assertIn('skipping duplicate', result.stderr)
        self.assertEqual(len(self.outgoing()), 1)

    def test_operator_channel_does_not_promise_signal_receipt(self):
        self.inbound('hal', chat_tests.UUID_A, receipt=False)
        result = self.chat('reply', '--reply-to', chat_tests.UUID_A, 'hal', 'Local result')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('no Signal submission or Signal receipt exists', result.stderr)
        self.assertNotIn('submission is pending', result.stderr)

    def test_actions_resolves_both_ids_and_rejects_wrong_room(self):
        request = self.inbound(self.bob, chat_tests.UUID_B)
        for ref in [request, chat_tests.UUID_B, chat_tests.UUID_B[:8]]:
            self.assertEqual(client.resolve_reply(ref, self.bob), (request, chat_tests.UUID_B))
            with self.assertRaises(ValueError): client.resolve_reply(ref, self.alice)


class DraftTests(unittest.TestCase):
    def setUp(self):
        t = tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup); self.root = Path(t.name)
        p = patch.dict(os.environ, {'IDENTITY_DIR': str(self.root), 'TRAJ_ID': ''}); p.start(); self.addCleanup(p.stop)
        (self.root/'social-policy.json').write_text('{}')
        self.payload = {'request_id': 'example', 'target': 'dm:hal', 'message': 'original'}

    def cli(self, payload, *args):
        stdout = io.StringIO()
        with patch.object(sys, 'argv', ['custos-actions', *args]), patch.object(sys, 'stdin', io.TextIOWrapper(io.BytesIO(json.dumps(payload).encode()))), patch('sys.stdout', stdout):
            rc = client.main()
        return rc, json.loads(stdout.getvalue())

    def test_goal_association_survives_retry_without_goal_flag(self):
        self.assertEqual(drafts.associate_goal('example', 'goal-one'), 'goal-one')
        self.assertEqual(drafts.associate_goal('example', None), 'goal-one')
        with self.assertRaises(ValueError): drafts.associate_goal('example', 'goal-two')

    def test_changed_staged_payload_refused_without_goal_before_host(self):
        drafts.stage(self.payload)
        with patch.object(client, 'call') as host:
            rc, result = self.cli({**self.payload, 'message': 'changed'}, 'signal-send')
        self.assertEqual(rc, 2); self.assertFalse(result['host_write_attempted']); host.assert_not_called()
        self.assertEqual(result['origin'], 'local-client')

    def test_same_guard_with_goal_and_without_goal(self):
        drafts.stage(self.payload)
        item = (None, None, None, {'id': 'goal'}, {'status': 'active', 'goal': {}, 'origin': {}})
        with patch.object(cm, 'Store') as store, patch.object(cm, 'is_task', return_value=True), patch.object(client, 'call') as host:
            store.return_value.find.return_value = item
            for args in [[], ['--goal', 'goal']]:
                rc, _ = self.cli({**self.payload, 'message': 'changed'}, 'signal-send', *args)
                self.assertEqual(rc, 2)
        host.assert_not_called()

    def revision(self):
        p = drafts.stage(self.payload)
        return {'request_id': 'example', 'expected_sha256': hashlib.sha256(p.read_bytes()).hexdigest(), 'replacement': {**self.payload, 'message': 'corrected'}}

    def test_revision_requires_exact_preimage_and_unknown_never_attempted(self):
        request = self.revision(); host = Mock(return_value=(200, {'ok': False, 'error': 'unknown_request'}))
        with self.assertRaises(ValueError): drafts.revise({**request, 'expected_sha256': 'wrong'}, host)
        host.assert_not_called()
        result = drafts.revise(request, host)
        self.assertTrue(result['ok']); self.assertEqual(json.loads(drafts.path('example').read_text())['message'], 'corrected')
        self.assertEqual(len(list(drafts.directory().glob('*.before-*'))), 1)

    def test_legacy_stage_without_attempt_provenance_cannot_be_revised(self):
        request = self.revision(); drafts.path('example').with_suffix('.created.json').unlink()
        host = Mock(return_value=(200, {'ok': False, 'error': 'unknown_request'}))
        with self.assertRaises(ValueError): drafts.revise(request, host)
        host.assert_not_called()

    def test_attempt_marker_blocks_revision_even_if_host_lost_record(self):
        request = self.revision(); drafts.mark_attempt(self.payload, self.payload)
        host = Mock(return_value=(200, {'ok': False, 'error': 'unknown_request'}))
        with self.assertRaises(ValueError): drafts.revise(request, host)
        host.assert_not_called()

    def test_host_pending_or_submitted_or_unavailable_never_revision(self):
        request = self.revision()
        for result in [(200, {'ok': True, 'phase': 'queued'}), (200, {'ok': True, 'phase': 'submitted'}), (503, {'ok': False, 'error': 'unknown_request'})]:
            with self.assertRaises(ValueError): drafts.revise(request, Mock(return_value=result))
        self.assertEqual(json.loads(drafts.path('example').read_text()), self.payload)

    def batch(self, request_id='ainews-one'):
        p = self.root/'apple.txt'; p.write_text('Apple research: qualified claim')
        return drafts.prepare_batch({'request_id': request_id, 'target': 'dm:hal', 'items': [{'key': 'https://apple.example/paper', 'path': str(p)}]})

    def test_individual_correction_invalidates_grouped_text(self):
        batch = self.batch(); drafts.stage(batch)
        (self.root/'apple.txt').write_text('Apple research: corrected claim')
        with self.assertRaises(ValueError): drafts.validate_sources(batch)
        rebuilt = drafts.prepare_batch({'request_id': batch['request_id'], 'target': batch['target'], 'items': [{'key': s['key'], 'path': s['path']} for s in batch['draft_sources']]})
        self.assertIn('corrected claim', rebuilt['message']); self.assertNotIn('qualified claim', rebuilt['message'])
        request = {'request_id': batch['request_id'], 'expected_sha256': hashlib.sha256(drafts.raw(batch)).hexdigest(), 'replacement': rebuilt}
        drafts.revise(request, Mock(return_value=(200, {'ok': False, 'error': 'unknown_request'})))
        self.assertEqual(json.loads(drafts.path(batch['request_id']).read_text()), rebuilt)

    def test_previous_success_or_uncertainty_reserves_news_item(self):
        first = self.batch(); drafts.stage(first); drafts.mark_attempt(first, first)
        next_batch = {**first, 'request_id': 'ainews-two'}
        for phase in ['submitted', 'queued', 'uncertain', 'unknown']:
            with self.assertRaises(ValueError): drafts.check_duplicate_items(next_batch, Mock(return_value=(200, {'phase': phase})))
        drafts.check_duplicate_items(next_batch, Mock(return_value=(200, {'phase': 'blocked'})))

    def test_legacy_delivered_items_are_not_repeated_after_upgrade(self):
        batch = self.batch()
        (drafts.directory()/'legacy-news-history.json').write_text(json.dumps([{'request_id': 'ainews-legacy', 'keys': [batch['draft_sources'][0]['key']]}]))
        with self.assertRaises(ValueError): drafts.check_duplicate_items(batch, Mock(return_value=(200, {'phase': 'submitted'})))

    def test_client_marks_attempt_before_call_and_keeps_it_on_timeout(self):
        def host(payload, **kwargs):
            self.assertTrue(drafts.attempted('example').exists()); raise OSError('timeout')
        with patch.object(client, 'guard', return_value={'ok': True}), patch.object(client, 'call', side_effect=host):
            rc, result = self.cli(self.payload, 'signal-send')
        self.assertEqual(rc, 2); self.assertTrue(drafts.attempted('example').exists())

    def test_news_batch_boundary_uses_successful_submission_not_queue_time(self):
        at = dt.datetime.now(dt.timezone.utc).timestamp()
        row = {'reference': 'action:ainews-prior', 'phase': 'submitted', 'created': at-7200,
               'receipt': {'timestamp': (at-3600)*1000, 'results': [{'type': 'SUCCESS'}]}}
        host = Mock(return_value=(200, {'ok': True, 'outgoing': [row]})); store = Mock(); store.files.return_value = []
        decision = news.check_batch(self.batch(), 'dm:hal', host, store, at)
        self.assertFalse(decision['ok']); self.assertEqual(decision['reason'], 'batch-window')
        self.assertEqual(dt.datetime.fromisoformat(decision['wait']['check_at']).timestamp(), at+5*3600)
        row['phase'] = 'blocked'
        self.assertTrue(news.check_batch(self.batch(), 'dm:hal', host, store, at)['ok'])

    def test_batch_deadline_is_checked_before_shorter_contact_cooldown(self):
        batch = self.batch()
        with patch.object(news, 'check_batch', return_value={'ok':False, 'reason':'batch-window', 'meaning':'group news later', 'wait':{'check_at':'2026-10-15T04:00:00+00:00'}}), patch.object(client, 'guard') as contact, patch.object(client, 'call') as host:
            rc, result = self.cli(batch, 'signal-send')
        self.assertEqual(rc, 1); self.assertEqual(result['reason'], 'batch-window')
        contact.assert_not_called(); host.assert_not_called()

    def test_pending_correction_preempts_optional_digest(self):
        store=Mock(); store.files.return_value=[(None,None,None,{'id':'correction-goal'}, {'status':'active','origin':{'request_id':'correction:old','sender':'operator:ai-news-review'}})]
        host=Mock()
        result=news.check_batch(self.batch(),'dm:hal',host,store)
        self.assertEqual(result['wait'],{'dependency_goal':'correction-goal'});host.assert_not_called()


class MemoryTests(memory_tests.MemoryFixture):
    def capture(self):
        return self.store.capture({**self.payload, 'outcome': 'Find sources', 'next_action': 'Read', 'completion': 'Checked'}, trigger_step='inbound', deferred=True)['goal_id']

    def test_action_goal_association_prevents_false_completion(self):
        goal = self.capture()
        row={'type':'message','from':'custos','to':'signal-room','goal_id':goal,'delivered_by':'custos-actions','request_id':'send','delivery_kind':'completion'}
        with patch.dict(os.environ,{'TRAJ_ID':'fixture'}), patch.object(cm,'trajectory',return_value=iter([row])), patch.object(cm,'delivery_status',return_value={'phase':'blocked'}):
            with self.assertRaises(cm.MemoryError): self.store.complete({'goal_id':goal,'disposition':'completed','evidence':'queued'})
        self.assertEqual(self.store.find(goal)[4]['status'],'active')

    def test_missing_trajectory_append_cannot_hide_attempted_goal_delivery(self):
        goal = self.capture()
        payload = {'request_id':'lost-log', 'target':'dm:hal', 'message':'result'}
        with patch.dict(os.environ, {'IDENTITY_DIR':str(self.root), 'TRAJ_ID':''}):
            drafts.stage(payload); drafts.associate_goal('lost-log',goal); drafts.mark_attempt(payload,payload)
            with patch.object(cm,'delivery_status',return_value={'phase':'queued'}):
                with self.assertRaises(cm.MemoryError): self.store.complete({'goal_id':goal,'disposition':'completed','evidence':'work done'})
        self.assertEqual(self.store.find(goal)[4]['status'],'active')

    def test_unchanged_terminal_receipt_wait_does_not_resume(self):
        goal=self.capture()
        with patch.object(cm,'delivery_status',return_value={'phase':'blocked'}):
            result=self.store.wait({'goal_id':goal,'reason':'Wait for changed receipt','receipt':'action:send'})
            self.assertIsNone(cm.wait_event(result['waiting'],self.store))
            self.assertNotIn('check_at',result['waiting'])
        with patch.object(cm,'delivery_status',return_value={'phase':'submitted'}):
            self.assertIn('submitted',cm.wait_event(result['waiting'],self.store))

    def test_dependency_wait_resumes_only_when_dependency_resolved(self):
        goal=self.capture()
        other=self.store.capture({**self.payload,'request_id':'other','outcome':'Another ask','next_action':'Read','completion':'Checked'},deferred=True)['goal_id']
        wait=self.store.wait({'goal_id':goal,'reason':'Correction first','dependency_goal':other})['waiting']
        self.assertIsNone(cm.wait_event(wait,self.store))
        self.store.complete({'goal_id':other,'disposition':'declined','evidence':'No correction needed'})
        self.assertIsNotNone(cm.wait_event(wait,self.store))

    def test_duplicate_review_suppresses_only_unchanged_comparison(self):
        old = self.capture()
        self.store.complete({'goal_id': old, 'disposition': 'completed', 'evidence': 'Source checked'})
        current = self.store.capture({**self.payload, 'request_id': 'later', 'outcome': 'Find sources', 'next_action': 'Read', 'completion': 'Checked'}, deferred=True)['goal_id']
        self.assertEqual(self.store.context()['goals'][0]['possible_duplicate_of'], old)
        self.store.duplicate_review({'goal_id': current, 'duplicate_of': old, 'evidence': 'Different source range was requested'})
        self.assertNotIn('possible_duplicate_of', self.store.context()['goals'][0])
        self.store.update({'goal_id': current, 'outcome': 'Find primary sources', 'evidence': 'Scope changed'})
        self.assertEqual(self.store.context()['goals'][0]['possible_duplicate_of'], old)

    def test_new_wait_conditions_preserve_previous_record_schema(self):
        goal = self.capture()
        with patch.object(cm, 'delivery_status', return_value={'phase':'blocked'}):
            self.store.wait({'goal_id':goal,'reason':'receipt change','receipt':'action:send'})
        record = self.store.find(goal)[4]
        self.assertEqual(set(record['waiting']), {'reason','since','resume_sender','receipt'})
        self.assertNotIn('receipt_phase', record['waiting'])
        with patch.object(cm, 'delivery_status', return_value={'phase':'blocked'}):
            self.assertEqual(self.store.context()['waiting'][0]['receipt_phase'], 'blocked')
        # A changed wait must not inherit a prior receipt phase or dependency.
        changed = {**record['waiting'], 'reason':'new decision'}
        self.assertNotIn('receipt_phase', self.store.wait_condition(goal, changed))

    def test_identical_note_does_not_rewrite_memory(self):
        goal=self.capture(); self.store.note({'goal_id':goal,'text':'No new evidence'})
        before=self.store.find(goal)[0].read_bytes()
        result=self.store.note({'goal_id':goal,'text':'No new evidence'})
        self.assertTrue(result['unchanged']);self.assertEqual(self.store.find(goal)[0].read_bytes(),before)

    def test_dream_finds_blocked_delivery_without_failure_prose(self):
        goal=self.capture(); log=self.root/'trajectory.jsonl'
        log.write_text(json.dumps({'ts':dt.datetime.now(dt.timezone.utc).isoformat(),'type':'message','from':'custos','to':'signal-room','step_id':'out','reply_to':'inbound','content':'Recipe confirmation sent'})+'\n')
        with patch.object(client,'call',return_value=(200,{'ok':True,'results':{'outbox:out':{'phase':'blocked'}}})):
            issues=dream.Dream(self.store).delivery_issues(path=log)
        self.assertEqual(issues[0]['goal_id'],goal);self.assertEqual(issues[0]['phase'],'blocked')


if __name__ == '__main__': unittest.main()
