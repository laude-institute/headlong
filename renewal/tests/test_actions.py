import copy
import io
import json
from pathlib import Path
import sqlite3
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import Mock, patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import custos_actions as ca
import custos_signal as cs
import custos_automata_deploy as cad
from test_signal import POLICY, HAL, BOT, STRANGER


class ActionsTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.policy=self.root/'policy.json';self.policy.write_text(json.dumps(POLICY))
        self.state=self.root/'actions.sqlite';self.channel=ca.Channel(self.state,self.policy)
        self.bridge=cs.Bridge(self.policy,cs.Spool(self.root/'signal.sqlite'),self.state)
        self.addCleanup(self.bridge.spool.db.close)
        self.bridge.rpc=Mock()
        self.bridge.rpc.call.return_value={'timestamp':1234,'results':[{'type':'SUCCESS'}]}
        self.p={'action':'signal-send','request_id':'one','target':'Hal','message':'Hello'}

    def status(self): return self.channel.handle({'action':'status','request_id':'one'})

    def test_proactive_dm_without_any_inbound_and_replay(self):
        self.assertEqual(self.channel.handle(self.p)['phase'],'queued')
        self.assertEqual(self.channel.handle(self.p)['phase'],'queued')
        with patch.object(cs,'paused',return_value=False):
            self.bridge.proactive(); self.bridge.proactive()
        self.bridge.rpc.call.assert_called_once_with('send',{'message':'Hello','recipient':[HAL]})
        self.assertEqual(self.status()['phase'],'submitted')
        self.assertEqual(self.channel.handle(self.p)['phase'],'submitted')
        with self.assertRaises(ValueError): self.channel.handle({**self.p,'message':'different'})

    def test_inline_ask_holds_the_dm_until_the_answer_is_read_or_the_wait_ends(self):
        """Hal/Jack/Kim 2026-09-10: Custos asks Kim inline; her reply is read by the asking step,
        never delivered as a wake, until the hold is released or expires (then it is annotated)."""
        KIM = '00000000-0000-4000-8000-00000000000b'
        policy = copy.deepcopy(POLICY); policy['people'][KIM] = {'label': 'Kim', 'authority': 'external', 'bot': True}
        self.policy.write_text(json.dumps(policy))
        self.channel.spool = str(self.root / 'signal.sqlite')
        ask = {'action': 'signal-ask', 'request_id': 'ask-1', 'target': 'Kim', 'message': 'Research request: what is a levain? [done] please', 'wait_seconds': 120}
        with self.assertRaises(ValueError):  # groups cannot be held
            self.channel.handle({**ask, 'target': 'Group'})
        r = self.channel.handle(ask)
        self.assertEqual((r['phase'], r['conversation']), ('queued', 'dm:' + KIM))
        with self.assertRaises(ValueError):  # one open ask per conversation
            self.channel.handle({**ask, 'request_id': 'ask-2'})
        with patch.object(cs, 'paused', return_value=False):
            self.bridge.proactive()
        self.bridge.rpc.call.assert_called_once_with('send', {'message': ask['message'], 'recipient': [KIM]})
        # Kim answers in two messages: pending in the spool, but never delivered while held.
        base = int((r['hold_expires'] - 120) * 1000) + 5000
        from test_signal import envelope
        for n, text in enumerate(['A levain is a sourdough preferment.', 'Flour, water, starter. [done]']):
            item = cs.classify(envelope(sender=KIM, message=text, timestamp=base + n * 1000), policy)
            self.bridge.spool.receive(item)
            with self.bridge.spool.db:
                self.bridge.spool.db.execute('UPDATE inbox SET arrived=? WHERE id=?', (0.0, item['request_id']))
        sent = []
        with patch.object(cs, 'transport', side_effect=lambda args, content='': sent.append(content) or {'queued': True}):
            self.bridge.deliver_pending(self.bridge.spool.db)
        self.assertEqual(sent, [])
        got = self.channel.handle({'action': 'signal-await', 'request_id': 'ask-1'})
        self.assertEqual([x['body'] for x in got['replies']], ['A levain is a sourdough preferment.', 'Flour, water, starter. [done]'])
        self.assertTrue(got['hold_active'])
        self.assertEqual({row[0] for row in self.bridge.spool.db.execute("SELECT phase FROM inbox")}, {'consumed'})
        self.assertEqual(self.channel.handle({'action': 'signal-await', 'request_id': 'ask-1'})['replies'][0]['body'], 'A levain is a sourdough preferment.')
        self.assertTrue(self.channel.handle({'action': 'signal-release', 'request_id': 'ask-1'})['released'])
        self.assertFalse(self.channel.handle({'action': 'signal-await', 'request_id': 'ask-1'})['hold_active'])
        # Consumed rows never surface as wakes even after release.
        with patch.object(cs, 'transport', side_effect=lambda args, content='': sent.append(content) or {'queued': True}):
            self.bridge.deliver_pending(self.bridge.spool.db)
        self.assertEqual(sent, [])
        # A second ask too soon is refused; after the spacing it is fine; the budget is a day's worth.
        with self.assertRaises(ValueError):
            self.channel.handle({**ask, 'request_id': 'ask-3'})
        with ca.connect(self.state) as db:
            db.execute("UPDATE actions SET created=created-100 WHERE id='ask-1'")
        r3 = self.channel.handle({**ask, 'request_id': 'ask-3', 'wait_seconds': 30})
        # The wait ends without an answer: the late reply is delivered as a wake, annotated.
        with ca.connect(self.state) as db:
            db.execute("UPDATE holds SET expires=? WHERE request_id='ask-3'", (r3['hold_expires'] - 31,))
        late = cs.classify(envelope(sender=KIM, message='Sorry, late: it is a preferment.', timestamp=base + 900000), policy)
        self.bridge.spool.receive(late)
        with self.bridge.spool.db:
            self.bridge.spool.db.execute('UPDATE inbox SET arrived=? WHERE id=?', (0.0, late['request_id']))
        with patch.object(cs, 'transport', side_effect=lambda args, content='': sent.append(content) or {'queued': True}):
            self.bridge.deliver_pending(self.bridge.spool.db)
        self.assertEqual(len(sent), 1); self.assertIn('answer to your inline ask ask-3', sent[0])
        with ca.connect(self.state) as db:
            for n in range(ca.ASK_DAILY):
                db.execute('INSERT INTO actions(id,payload,created) VALUES(?,?,?)', ('b%d' % n, ca.encoded({'action': 'signal-ask'}), 1e12))
            db.execute("UPDATE actions SET created=strftime('%s','now')-1000 WHERE id LIKE 'b%'")
        with self.assertRaises(ValueError):
            self.channel.handle({**ask, 'request_id': 'ask-9'})

    def test_every_allowlisted_person_and_only_the_approved_group_resolve(self):
        for dest in ca.destinations(POLICY): self.assertEqual(ca.resolve(dest['target'],POLICY),dest['target'])
        labelled = {**POLICY, 'groups': ['g1', 'g2'], 'group_labels': {'g1': 'Collette Haus'}}
        groups = [d for d in ca.destinations(labelled) if d['kind'] == 'group']
        self.assertEqual([d['label'] for d in groups], ['Collette Haus', 'Group'])
        self.assertEqual(ca.resolve('collette haus', labelled), 'group:g1')
        self.assertEqual(ca.resolve('group:g2', labelled), 'group:g2')
        for target in ('dm:'+STRANGER,'group:other','wife-not-verified'):
            with self.assertRaises(ValueError): self.channel.handle({**self.p,'target':target})
        for key in ('socket','command','container','recipient'):
            with self.assertRaises(ValueError): self.channel.handle({**self.p,key:'ignored?'})

    def test_group_topic_needs_live_safe_membership(self):
        self.p['target']='Group';self.channel.handle(self.p)
        group={'id':'agreed-group','isMember':True,'members':[BOT,HAL]}
        self.bridge.rpc.call.side_effect=[[group],{'timestamp':12,'results':[{'type':'SUCCESS'}]}]
        with patch.object(cs,'paused',return_value=False): self.bridge.proactive()
        self.assertEqual(self.status()['phase'],'submitted')
        self.assertEqual(self.bridge.rpc.call.call_args.args,('send',{'message':'Hello','groupId':'agreed-group'}))

    def test_changed_allowlist_or_group_blocks_queued_message(self):
        self.channel.handle(self.p)
        policy=copy.deepcopy(POLICY);del policy['people'][HAL];self.policy.write_text(json.dumps(policy))
        with patch.object(cs,'paused',return_value=False): self.bridge.proactive()
        self.assertEqual(self.status()['phase'],'blocked');self.bridge.rpc.call.assert_not_called()

    def test_blocked_receipt_explains_no_retry_and_survives_policy_recovery(self):
        from custos_actions_client import explain_status
        self.channel.handle(self.p)
        policy=copy.deepcopy(POLICY);del policy['people'][HAL];self.policy.write_text(json.dumps(policy))
        with patch.object(cs,'paused',return_value=False):self.bridge.proactive()
        result=explain_status(self.status())
        self.assertEqual(result['phase'],'blocked')
        self.assertTrue(result['delivery_state']['terminal'])
        self.assertFalse(result['delivery_state']['automatic_retry'])
        self.assertIn('will not automatically retry',result['delivery_state']['meaning'])
        self.assertEqual(result['receipt'],self.status()['receipt'])
        self.policy.write_text(json.dumps(POLICY))
        with patch.object(cs,'paused',return_value=False):
            self.bridge.proactive();self.bridge.proactive()
        self.assertEqual(self.status()['phase'],'blocked');self.bridge.rpc.call.assert_not_called()
        self.assertEqual(self.channel.handle(self.p)['phase'],'blocked')

    def test_new_group_member_blocks_send(self):
        self.channel.handle({**self.p,'target':'Group'})
        self.bridge.rpc.call.return_value=[{'id':'agreed-group','isMember':True,'members':[BOT,HAL,STRANGER]}]
        with patch.object(cs,'paused',return_value=False): self.bridge.proactive()
        self.assertEqual(self.status()['phase'],'blocked')
        self.bridge.rpc.call.assert_called_once_with('listGroups',{'detailed':True})

    def test_pause_and_shared_route_pacing(self):
        self.channel.handle(self.p)
        with patch.object(cs,'paused',return_value=True): self.bridge.proactive()
        self.assertEqual(self.status()['phase'],'queued');self.bridge.rpc.call.assert_not_called()
        route='signal-'+cs.hashlib.sha256(('dm:'+HAL).encode()).hexdigest()[:24]
        self.bridge.last_send[route]=cs.time.monotonic()
        with patch.object(cs,'paused',return_value=False): self.bridge.proactive()
        self.bridge.rpc.call.assert_not_called()

    def test_ambiguous_send_and_restart_never_retry(self):
        self.channel.handle(self.p);self.bridge.rpc.call.side_effect=TimeoutError()
        with patch.object(cs,'paused',return_value=False),self.assertRaises(TimeoutError): self.bridge.proactive()
        self.assertEqual(self.status()['phase'],'uncertain')
        with patch.object(cs,'paused',return_value=False): self.bridge.proactive()
        self.assertEqual(self.bridge.rpc.call.call_count,1)
        with ca.connect(self.state) as db: db.execute("UPDATE actions SET phase='sending'")
        cs.Bridge(self.policy,self.bridge.spool,self.state)
        self.assertEqual(self.status()['phase'],'uncertain')

    def test_deploy_requires_exact_fields_commit_and_goal(self):
        p={'action':'automata-deploy','request_id':'deploy-one','goal_id':'0123abcd','commit':'a'*40}
        self.assertEqual(self.channel.handle(p)['phase'],'queued')
        for extra in ({'commit':'main'},{'commit':'a'*40+';reboot'},{'container':122},{'path':'/'},{'goal_id':'bad'}):
            with self.assertRaises(ValueError): self.channel.handle({**p,**extra})

    def test_host_command_output_is_bounded_and_failure_is_not_success(self):
        with self.assertRaises(ValueError): ca.run_bounded([sys.executable,'-c','print("x"*1000)'],maximum=10)
        with self.assertRaises(RuntimeError): ca.run_bounded([sys.executable,'-c','raise SystemExit(2)'])


class DeployTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
    def archive(self,name,kind=tarfile.REGTYPE):
        path=self.root/'source.tar'
        with tarfile.open(path,'w') as tf:
            item=tarfile.TarInfo(name);item.type=kind
            item.linkname='/outside';item.size=0;tf.addfile(item,io.BytesIO(b''))
        return path
    def test_archive_links_traversal_and_persistent_data_rejected(self):
        for name,kind in [('../evil',tarfile.REGTYPE),('/evil',tarfile.REGTYPE),
                          ('link',tarfile.SYMTYPE),('hard',tarfile.LNKTYPE),('device',tarfile.CHRTYPE),
                          ('species/saved.json',tarfile.REGTYPE),('.env',tarfile.REGTYPE)]:
            dest=self.root/'dest';dest.mkdir(exist_ok=True)
            with self.subTest(name=name),self.assertRaises(ValueError): cad.extract(self.archive(name,kind),dest)
        self.assertFalse((self.root/'evil').exists())

    def test_source_identity_ignores_archive_timestamps_but_detects_code_changes(self):
        roots=[]
        for number,mtime in enumerate((100,200)):
            archive=self.root/f'source-{number}.tar'
            with tarfile.open(archive,'w') as tf:
                for name in ('server.js','sim.js','sim.test.js','index.html'):
                    item=tarfile.TarInfo(name);item.mtime=mtime;item.mode=0o644
                    content=b'unchanged code';item.size=len(content);tf.addfile(item,io.BytesIO(content))
            dest=self.root/f'release-{number}';dest.mkdir();cad.extract(archive,dest);roots.append(dest)
        self.assertNotEqual((self.root/'source-0.tar').read_bytes(),(self.root/'source-1.tar').read_bytes())
        self.assertEqual(cad.source_digest(roots[0]),cad.source_digest(roots[1]))
        (roots[1]/'.source-sha256').write_text('old wire digest')
        (roots[1]/'species').symlink_to(self.root/'persistent-data')
        self.assertEqual(cad.source_digest(roots[0]),cad.source_digest(roots[1]))
        (roots[1]/'server.js').write_text('changed source')
        self.assertNotEqual(cad.source_digest(roots[0]),cad.source_digest(roots[1]))
    def test_health_failure_restores_previous_release(self):
        state=self.root/'state.json';original={'current':'/previous','commit':'a'*40,'previous':None,'previous_commit':None}
        state.write_text(json.dumps(original))
        with patch.object(cad,'STATE',state),patch.object(cad,'switch') as switch,patch.object(cad,'run'), \
             patch.object(cad,'wait_healthy',side_effect=[RuntimeError(),None]),patch.object(cad,'status',return_value={'healthy':True}):
            result=cad.activate(Path('/candidate'),'b'*40)
        self.assertFalse(result['ok']);self.assertTrue(result['rolled_back'])
        self.assertEqual([c.args[0] for c in switch.call_args_list],[Path('/candidate'),Path('/previous')])
        self.assertEqual(json.loads(state.read_text()),original)
    def test_success_retains_previous_commit_for_explicit_rollback(self):
        state=self.root/'state.json';state.write_text(json.dumps({'current':'/previous','commit':'a'*40}))
        with patch.object(cad,'STATE',state),patch.object(cad,'switch'),patch.object(cad,'run'), \
             patch.object(cad,'wait_healthy'),patch.object(cad,'status',return_value={'healthy':True}):
            self.assertTrue(cad.activate(Path('/candidate'),'b'*40)['ok'])
        self.assertEqual(json.loads(state.read_text())['previous_commit'],'a'*40)

if __name__=='__main__': unittest.main()


class ActionsClientTests(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
        import custos_actions_client as cac
        self.cac = cac

    def test_route_matches_the_bridge_and_labels_resolve_uniquely(self):
        import hashlib
        self.assertEqual(self.cac.route_for('dm:8f14-aci'), 'signal-' + hashlib.sha256(b'dm:8f14-aci').hexdigest()[:24])
        contacts = [{'target': 'dm:8f14-aci', 'label': 'Dani', 'kind': 'dm'}, {'target': 'group:abc=', 'label': 'Group', 'kind': 'group'}]
        self.assertEqual(self.cac.resolve_target('dani', contacts), 'dm:8f14-aci')
        self.assertEqual(self.cac.resolve_target('group:abc=', contacts), 'group:abc=')
        with self.assertRaises(ValueError):
            self.cac.resolve_target('nobody', contacts)

    def test_guard_refuses_blocked_allowance_and_chat_verdicts(self):
        with patch.dict('os.environ', {'CHAT_SOCIAL_BLOCKED': 'not sent: allowance used'}, clear=False):
            with self.assertRaises(ValueError) as caught:
                self.cac.guard('signal-x')
            self.assertIn('allowance used', str(caught.exception))
        with patch('custos_contact_guard.check', return_value={'ok':False,'reason':'cooldown','error':'you spoke last'}) as check:
            with self.assertRaises(ValueError) as caught: self.cac.guard('signal-x')
            self.assertIn('you spoke last',str(caught.exception));check.assert_called_once_with('signal-x')
        # No environment override now uses the installed mind policy.
        with patch('custos_contact_guard.check', return_value={'ok':True,'hours':2}):
            self.assertEqual(self.cac.guard('signal-x')['hours'],2)

    def test_send_refused_by_guard_never_reaches_the_service_and_accepted_send_is_recorded(self):
        calls = []
        def fake_call(payload):
            calls.append(payload)
            if payload == {'action': 'signal-contacts'}:
                return 200, {'ok': True, 'contacts': [{'target': 'dm:aci-1', 'label': 'Dani', 'kind': 'dm'}]}
            return 200, {'ok': True, 'phase': 'queued', 'request_id': payload['request_id']}
        recorded = []
        body = json.dumps({'request_id': 'signal-test-1', 'target': 'Dani', 'message': 'hello'})
        with patch.object(self.cac, 'call', side_effect=fake_call), patch.object(self.cac, 'record', side_effect=lambda *a, **kw: recorded.append(a)), \
                patch.object(sys, 'argv', ['custos-actions', 'signal-send']), patch.object(sys, 'stdin', io.TextIOWrapper(io.BytesIO(body.encode()))), \
                patch.dict('os.environ', {'CHAT_SOCIAL_BLOCKED': 'not sent: blocked for the test', 'CHAT_DOUBLE_TEXT_GUARD_HOURS': ''}, clear=False), \
                patch('sys.stdout', new_callable=io.StringIO) as out:
            rc = self.cac.main()
        self.assertEqual(rc, 1)
        self.assertIn('blocked for the test', out.getvalue())
        self.assertEqual([c['action'] for c in calls], ['signal-contacts'])  # resolved the label, never sent
        self.assertEqual(recorded, [])
        calls.clear()
        with patch.object(self.cac, 'call', side_effect=fake_call), patch.object(self.cac, 'record', side_effect=lambda *a, **kw: recorded.append(a)), \
                patch.object(sys, 'argv', ['custos-actions', 'signal-send']), patch.object(sys, 'stdin', io.TextIOWrapper(io.BytesIO(body.encode()))), \
                patch.dict('os.environ', {'CHAT_SOCIAL_BLOCKED': '', 'CHAT_DOUBLE_TEXT_GUARD_HOURS': ''}, clear=False), \
                patch('custos_contact_guard.check',return_value={'ok':True}), \
                patch('sys.stdout', new_callable=io.StringIO) as out:
            rc = self.cac.main()
        self.assertEqual(rc, 0)
        self.assertEqual(calls[-1]['action'], 'signal-send')
        self.assertEqual(calls[-1]['target'], 'Dani')
        self.assertEqual(recorded, [(self.cac.route_for('dm:aci-1'), 'hello', 'signal-test-1', 'queued')])

class ActionSemanticsTests(unittest.TestCase):
    def test_no_phase_claims_success_or_discards_receipt(self):
        from custos_actions_client import explain_status
        for phase in ['queued','running','blocked','uncertain','submitted','succeeded','failed','new-phase']:
            raw={'ok':True,'phase':phase,'receipt':{'error':'sentinel'}}
            result=explain_status(raw)
            self.assertEqual(result['receipt'],raw['receipt'])
            self.assertEqual(set(raw),{'ok','phase','receipt'})
            self.assertEqual(result['delivery_state']['automatic_retry'],phase=='queued')
        self.assertEqual(explain_status({'ok':False}),{'ok':False})

    def test_cli_status_exposes_host_phase_without_sending(self):
        import custos_actions_client as client
        raw={'ok':True,'phase':'blocked','request_id':'one','receipt':{'error':'bot-error input already claimed'}}
        output=io.StringIO()
        with patch.object(sys,'argv',['custos-actions','status','one']), patch.object(client,'call',return_value=(200,raw)) as call, patch('sys.stdout',output):
            self.assertEqual(client.main(),0)
        call.assert_called_once_with({'action':'status','request_id':'one'})
        result=json.loads(output.getvalue())
        self.assertFalse(result['delivery_state']['automatic_retry'])
        self.assertEqual(result['receipt'],raw['receipt'])
