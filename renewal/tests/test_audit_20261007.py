"""Incident regressions: sealed identities, fake receipts/API; no real sends."""
import datetime as dt
import hashlib
import io
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import subprocess
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import custos_contact_guard as guard
import custos_actions_client as client
import custos_dream as dream
import custos_kitchen as kitchen
import custos_memory as cm
import custos_own_waits as own
import custos_review_publish as publish
from test_memory import MemoryFixture


class ContactTests(unittest.TestCase):
    def setUp(self):
        self.target = 'dm:alice'; self.route = guard.route_for(self.target)
        self.at = guard.timestamp('2026-10-07T12:00:00+00:00')
        self.row = {'from': 'custos', 'to': self.route, 'ts': guard.iso(self.at - 3*3600),
                    'request_id': 'news', 'delivered_by': 'custos-actions', 'content': 'a share'}
        self.proof = {'phase': 'submitted', 'receipt': {'timestamp': (self.at-3*3600)*1000, 'results': [{'type': 'SUCCESS'}]}}
    def decide(self, rows=None, proof=None, hours=12, cross=True):
        return guard.evaluate(rows or [self.row], self.target, self.route, hours, cross,
                              lambda ref: self.proof if proof is None else proof, self.at)
    def test_aliases_have_same_route(self):
        contacts = [{'target': self.target, 'label': 'Hal'}]
        self.assertEqual({guard.canonical(v, contacts) for v in ['Hal', 'hal', self.target, self.route]}, {(self.target, self.route)})
        with self.assertRaises(ValueError): guard.canonical('dm:unknown', contacts)
    def test_host_accepted_send_missing_from_trajectory_is_reserved_and_anchors(self):
        from unittest.mock import Mock
        with tempfile.TemporaryDirectory() as temp:
            (Path(temp)/'social-policy.json').write_text('{}')
            def broker(payload,timeout=3):
                if payload['action']=='signal-contacts':return 200,{'ok':True,'contacts':[{'label':'Hal','target':self.target}]}
                if payload['action']=='signal-contact-outbox':return 200,{'ok':True,'outgoing':[{'reference':'action:lost-client-response','created':self.at,**self.missing}]}
                self.fail(payload)
            with patch.dict(os.environ,{'IDENTITY_DIR':temp,'TRAJ_ID':'fixture'}),patch.object(client,'call',side_effect=broker),patch.object(guard,'indexed_rows',side_effect=lambda path:[]),patch.object(guard.subprocess,'run',return_value=Mock(stdout='/fixture/trajectory')):
                self.missing={'phase':'queued','record_found':True,'receipt':None}
                self.assertEqual(guard.check('Hal',hours=12,cross=False)['reason'],'delivery-unresolved')
                current=dt.datetime.now(dt.timezone.utc).timestamp()
                self.missing={'phase':'submitted','record_found':True,'receipt':{'timestamp':current*1000,'results':[{'type':'SUCCESS'}]}}
                self.assertEqual(guard.check('Hal',hours=12,cross=False)['reason'],'cooldown')

    def test_mode_and_exact_deadline(self):
        self.assertTrue(self.decide(hours=2, cross=False)['ok'])
        result = self.decide(); self.assertFalse(result['ok'])
        self.assertEqual(result['resume_at'], '2026-10-07T21:00:00+00:00')
        self.assertEqual(result['mode'], 'social')
    def test_terminal_unsent_never_becomes_contact(self):
        for phase in guard.UNSENT:
            self.assertTrue(self.decide(proof={'phase': phase})['ok'], phase)
    def test_earlier_success_still_anchors_after_blocked_message(self):
        old = {**self.row, 'request_id': 'old'}
        newest = {**self.row, 'request_id': 'new', 'ts': guard.iso(self.at)}
        result = guard.evaluate([old,newest],self.target,self.route,12,False,
                               lambda ref: self.proof if ref=='action:old' else {'phase':'blocked'},self.at)
        self.assertEqual(result['resume_at'], '2026-10-07T21:00:00+00:00')
    def test_unknown_send_reserves_even_after_time_or_inbound(self):
        reply = {'from': self.route, 'to': 'custos', 'ts': guard.iso(self.at), 'content': 'hi'}
        for phase in ['queued', 'running', 'pending', 'sending', 'uncertain', 'unknown', 'unavailable']:
            self.assertEqual(self.decide([self.row,reply], {'phase':phase}, hours=1)['reason'], 'delivery-unresolved')
    def test_real_reply_releases_and_reaction_does_not(self):
        reply = {'from': self.route, 'to': 'custos', 'ts': guard.iso(self.at), 'content': 'hi'}
        self.assertTrue(self.decide([self.row,reply])['ok'])
        reply['content'] = 'Signal reaction (ambient event): thumbs up'
        self.assertFalse(self.decide([self.row,reply])['ok'])
    def test_cross_room_preserved_and_reply_releases(self):
        group = 'signal-group'; intro = {'from':group,'to':'custos','ts':guard.iso(self.at-4*3600),'content':'{"scope":"group","aci":"alice"}'}
        outgoing = {**self.row,'to':group}
        self.assertFalse(self.decide([intro,outgoing])['ok'])
        self.assertTrue(self.decide([intro,outgoing],cross=False)['ok'])
        reply = {'from':self.route,'to':'custos','ts':guard.iso(self.at),'content':'{"aci":"alice"} Hi'}
        self.assertTrue(self.decide([intro,outgoing,reply])['ok'])
    def test_receipt_timestamp_not_queue_timestamp_controls(self):
        proof = {'phase':'submitted','receipt':{'timestamp':self.at*1000,'results':[{'type':'SUCCESS'}]}}
        self.assertEqual(self.decide(proof=proof)['resume_at'],'2026-10-08T00:00:00+00:00')
    def test_partial_success_and_invalid_time_are_unknown(self):
        for receipt in [{'timestamp':self.at,'results':[{'type':'SUCCESS'},{'type':'FAILURE'}]},
                        {'timestamp':'broken','results':[{'type':'SUCCESS'}]}]:
            self.assertEqual(self.decide(proof={'phase':'submitted','receipt':receipt})['reason'],'delivery-unresolved')


    def test_index_recovers_legacy_action_ids_and_ignores_partial_lines(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'trajectory.jsonl'
            raw={'type':'message',**self.row,'step_id':'one'}
            path.write_text(json.dumps({'type':'header','id':'root'})+'\n'+json.dumps(raw)+'\n'+json.dumps({**raw,'step_id':'two'})[:-1])
            rows=guard.indexed_rows(path);self.assertEqual(len(rows),1)
            self.assertEqual(guard.reference(rows[0]),'action:news')
            with path.open('a') as f:f.write('}\n')
            self.assertEqual(len(guard.indexed_rows(path)),2)
            self.assertEqual(len(guard.indexed_rows(path)),2)
    def test_legacy_missing_record_cannot_block_forever_after_confirmed_later_contact(self):
        old={**self.row,'request_id':'old','ts':guard.iso(self.at-86400)}
        current={**self.row,'request_id':'current'}
        for missing,phase in [(True,'unknown'),(False,'uncertain')]:
            result=guard.evaluate([old,current],self.target,self.route,12,False,
                lambda ref:self.proof if ref=='action:current' else {'phase':phase,'record_found':not missing},self.at)
            self.assertEqual(result['reason'],'cooldown' if missing else 'delivery-unresolved')
        result=guard.evaluate([old],self.target,self.route,12,False,
                             lambda ref:{'phase':'unknown','record_found':False},self.at)
        self.assertEqual(result['reason'],'delivery-unresolved')

    def test_native_uncorrelated_line_never_queued_is_not_contact(self):
        row={k:v for k,v in self.row.items() if k not in {'request_id','delivered_by'}}
        row.update(step_id='old',source='chat')
        self.assertTrue(self.decide([row],{'phase':'unknown','record_found':False})['ok'])
        row['reply_to']='inbound'
        self.assertFalse(self.decide([row],{'phase':'unknown','record_found':False})['ok'])


class BatchReceiptTests(unittest.TestCase):
    def test_both_host_variants_read_compact_receipts_and_bound_batch(self):
        import custos_actions as actions
        import custos_signal as signal
        import importlib.util
        from test_signal import POLICY
        spec=importlib.util.spec_from_file_location('audit_host_actions',Path(actions.__file__).parent/'host-kitchen/custos_actions.py')
        host=importlib.util.module_from_spec(spec);spec.loader.exec_module(host)
        for module in [actions,host]:
            with tempfile.TemporaryDirectory() as temp:
                root=Path(temp);policy=root/'policy';policy.write_text(json.dumps(POLICY))
                spool=signal.Spool(root/'spool');self.addCleanup(spool.db.close)
                channel=module.Channel(root/'actions',policy,root/'spool')
                channel.handle({'action':'signal-send','request_id':'one','target':'Hal','message':'private text'})
                with module.connect(root/'actions') as db:
                    db.execute("UPDATE actions SET phase='submitted',receipt=? WHERE id='one'",(json.dumps({'timestamp':1234,'results':[{'type':'SUCCESS','recipient':'private'}]}),))
                result=channel.handle({'action':'delivery-status-batch','references':['action:one','outbox:missing']})
                self.assertTrue(result['results']['action:one']['record_found'])
                self.assertFalse(result['results']['outbox:missing']['record_found'])
                self.assertNotIn('private',json.dumps(result))
                contact=channel.handle({'action':'signal-contact-outbox','target':'Hal','since':0})
                self.assertEqual(contact['outgoing'][0]['reference'],'action:one')
                self.assertNotIn('private',json.dumps(contact))
                # No local trajectory index is involved in this host receipt read.
                with module.connect(root/'actions') as db:
                    db.execute("UPDATE actions SET phase='uncertain',created=0 WHERE id='one'")
                contact=channel.handle({'action':'signal-contact-outbox','target':'Hal','since':1})
                self.assertEqual(contact['outgoing'][0]['phase'],'uncertain')
                with self.assertRaises(ValueError):channel.handle({'action':'signal-contact-outbox','target':'Stranger','since':0})

                for refs in [[],['action:one']*129,['action:bad/../id'],[3]]:
                    with self.assertRaises(ValueError):channel.handle({'action':'delivery-status-batch','references':refs})


class KitchenTests(unittest.TestCase):
    def setUp(self):
        self.db=sqlite3.connect(':memory:'); self.db.row_factory=sqlite3.Row
        self.db.execute('CREATE TABLE inbox(id TEXT,payload TEXT)');self.addCleanup(self.db.close)
        self.policy={'people':{'dani':{'label':'Dani','authority':'operator'}}}
    def test_apple_news_and_domain_are_not_groceries(self):
        for body in ["Apple's ML research: RISED https://machinelearning.apple.com/research/rised", 'RISED: https://machinelearning.apple.com/research/rised', 'Apple Intelligence research paper']:
            self.assertIsNone(kitchen.delivery_block(self.db,self.policy,'dm:hal',body))
    def test_apple_news_deployment_notice_and_actual_recipe_are_distinct(self):
        body = 'The audit fixes include corrected Apple/news classification, structured contact waits, review deduplication, and accurate memory summaries.'
        self.assertIsNone(kitchen.delivery_block(self.db,self.policy,'dm:hal',body))
        self.assertIsNotNone(kitchen.delivery_block(self.db,self.policy,'dm:hal','Apple news: a recipe for dinner'))
    def test_tech_words_do_not_exempt_household_source_or_food(self):
        for body in ['Add apples to the cart; this is AI research', 'Apple research: buy milk', 'Apple slices for dinner']:
            self.assertIsNotNone(kitchen.delivery_block(self.db,self.policy,'dm:hal',body))
        self.db.execute('INSERT INTO inbox VALUES (?,?)',('request',json.dumps({'sender_aci':'dani','conversation':'dm:hal','body':'Add apples','timestamp':1000})))
        self.db.execute('INSERT INTO inbox VALUES (?,?)',('stop',json.dumps({'sender_aci':'dani','conversation':'dm:hal','body':"We're all set",'timestamp':2000})))
        self.assertIsNotNone(kitchen.delivery_block(self.db,self.policy,'dm:hal',"Apple ML research",'request'))


class OwnGoalTests(MemoryFixture):
    def test_own_wait_preserves_native_bytes_and_resumes_once(self):
        key=self.store.commit('Consider a useful personal follow-up',memory_type='todo');item=self.store.find(key);before=item[0].read_bytes()
        deadline=(dt.datetime.now(dt.timezone.utc)+dt.timedelta(hours=12)).isoformat()
        self.store.wait({'goal_id':key,'reason':'Local Signal cooldown (social); staged request one','signal_target':'dm:alice','check_at':deadline})
        self.assertEqual(item[0].read_bytes(),before);self.assertIsNone(self.store.find(key)[4])
        with patch.object(cm,'wait_event',return_value=None):
            result=self.store.context();self.assertIn(key,[r['goal_id'] for r in result['waiting']]);self.assertNotIn(key,[r['goal_id'] for r in result['goals']])
        with patch.object(cm,'wait_event',return_value='eligible'):
            self.assertIn(key,[r['goal_id'] for r in self.store.context()['goals']])
            self.assertIn(key,[r['goal_id'] for r in self.store.context()['goals']])
        self.assertEqual(len([e for e in own.get(self.store,item)['events'] if 'resumed' in e]),1)
        self.assertEqual(own.pending_contact(self.store,'dm:alice')['goal_id'],key)
        own.resolve_contact(self.store,item,'No longer useful; deadline has passed')
        self.assertIsNone(own.pending_contact(self.store,'dm:alice'))
    def test_changed_own_file_invalidates_wait_without_rewriting_it(self):
        key=self.store.commit('Optional follow-up',memory_type='todo');item=self.store.find(key)
        self.store.wait({'goal_id':key,'reason':'bot lane blocked','signal_target':'dm:bot'})
        item[0].write_text(item[0].read_text()+'\nReconsidered.\n')
        self.assertIsNone(own.get(self.store,self.store.find(key)))
    def test_exact_guard_deadline_is_parked(self):
        key=self.store.commit('Follow up when useful',memory_type='todo')
        deadline=(dt.datetime.now(dt.timezone.utc)+dt.timedelta(hours=5)).isoformat()
        refusal=client.GuardRefusal({'reason':'cooldown','resume_at':deadline,'error':'you spoke last'})
        with patch.dict(os.environ,{'IDENTITY_DIR':str(self.root)}),patch.object(cm,'Store',return_value=self.store):
            result=client.park_cooldown(key,{'request_id':'one','message':'hello','target':'dm:alice'},'dm:alice',True,refusal)
            self.assertEqual(result['waiting']['check_at'],deadline)
            with self.assertRaises(ValueError):client.park_cooldown(key,{'request_id':'one','message':'changed'},'dm:alice',True,refusal)
    def test_newer_news_parks_before_guard_or_host_send(self):
        key=self.store.commit('Consider personal follow-up',memory_type='todo')
        until=(dt.datetime.now(dt.timezone.utc)+dt.timedelta(hours=2)).isoformat()
        self.store.wait({'goal_id':key,'reason':'Local Signal cooldown (social); staged request original','signal_target':'dm:alice','check_at':until})
        news=self.store.capture({**self.payload,'request_id':'ai-news:one','sender':'operator:ai-news-review','authority':'operator'},deferred=True)['goal_id']
        payload={'request_id':'ai-news:one','target':'dm:alice','message':'A news link'}
        with patch.object(cm,'Store',return_value=self.store),patch.dict(os.environ,{'IDENTITY_DIR':str(self.root)}),patch.object(client,'guard') as guard_call,patch.object(client,'call') as host,patch.object(sys,'argv',['custos-actions','signal-send','--goal',news]),patch.object(sys,'stdin',io.TextIOWrapper(io.BytesIO(json.dumps(payload).encode()))),patch('sys.stdout',new_callable=io.StringIO) as output:
            self.assertEqual(client.main(),1)
        self.assertEqual(json.loads(output.getvalue())['contact_goal'],key)
        guard_call.assert_not_called();host.assert_not_called()
        self.assertIn(key,self.store.find(news)[4]['waiting']['reason'])
        self.assertIsNone(self.store.find(key)[4])

    def test_dream_keep_requires_scoped_summary_but_uncertainty_is_valid(self):
        key=self.store.commit('Signal DM double-text guard is 12h not 2h',memory_type='fact')
        d=dream.Dream(self.store,clock=lambda:dt.datetime(2026,10,7,10,0,tzinfo=dt.timezone.utc))
        d.begin();digest=dream.sha(self.store.find(key)[0].read_bytes())
        with self.assertRaisesRegex(ValueError,'summary lacks mode'):d.review(key,digest,'keep','Observed one social refusal')
        d.review(key,digest,'uncertain','Need to separate social and mind policy')
        self.assertEqual(dream.sha(self.store.find(key)[0].read_bytes()),digest)

    def test_dream_flags_overbroad_summary_even_when_body_qualifies(self):
        self.assertTrue(dream.unscoped_contact_rule('Signal DM double-text guard is 12h not 2h','Actually only social mode'))
        self.assertFalse(dream.unscoped_contact_rule('Signal guards: mind 2h, social 12h','Separate policies.'))


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.head='a'*40;self.reviews=[];self.posts=[];self.timeout=False
        self.patch=patch.object(publish,'api',side_effect=self.api);self.patch.start();self.addCleanup(self.patch.stop)
        self.receipt=patch.object(publish,'capture',side_effect=lambda repo,pr,head,rid:{'review_id':rid,'state':next(r['state'] for r in self.reviews if r['id']==rid),'head':head})
        self.receipt.start();self.addCleanup(self.receipt.stop)
    def api(self,path,payload=None,pages=False):
        if path=='user':return {'login':'custos-1f916'}
        if payload:
            self.posts.append(payload)
            if self.timeout:raise TimeoutError('uncertain')
            row={'id':len(self.reviews)+1,'user':{'login':'custos-1f916'},'commit_id':self.head,'state':publish.STATES[payload['event']],'submitted_at':'now','body':payload['body']}
            self.reviews.append(row);return row
        if '/reviews?' in path:return self.reviews
        if '/comments?' in path:return []
        return {'head':{'sha':self.head},'user':{'login':'other'}}
    def send(self,event='COMMENT',**kw):
        return publish.publish('1f916-ai/1f916',541,self.head,event,'Reviewed '+self.head+'; no issues found. Tests not run.',self.temp.name,'reviews',**kw)
    def test_same_head_disposition_deduplicates_but_verdict_change_publishes(self):
        self.send();result=self.send();self.assertTrue(result['deduplicated']);self.assertEqual(len(self.posts),1)
        self.send('APPROVE');self.assertEqual(len(self.posts),2)
        self.send('APPROVE');self.assertEqual(len(self.posts),2)
    def test_historical_unmarked_review_deduplicates(self):
        self.reviews=[{'id':99,'user':{'login':'custos-1f916'},'commit_id':self.head,'state':'COMMENTED','submitted_at':'earlier','body':'Old report'}]
        self.assertEqual(self.send()['review_id'],99);self.assertFalse(self.posts)
    def test_timeout_is_reserved_and_no_blind_retry(self):
        self.timeout=True
        with self.assertRaises(TimeoutError):self.send()
        self.timeout=False
        with self.assertRaisesRegex(ValueError,'not reconciled'):self.send()
        self.assertEqual(len(self.posts),1)
    def test_current_head_race_refuses_before_post(self):
        with self.assertRaisesRegex(ValueError,'head changed'):
            publish.publish('1f916-ai/1f916',541,'b'*40,'COMMENT','Reviewed '+'b'*40,self.temp.name,'reviews')
        self.assertFalse(self.posts)
    def test_unchanged_update_cannot_bypass_dedup(self):
        self.send()
        with self.assertRaisesRegex(ValueError,'unchanged body'):self.send(update_of=1,update_evidence='same conclusion again')
        self.assertEqual(len(self.posts),1)


    def test_direct_module_run_exits_nonzero_not_silent(self):
        module = str(Path(__file__).resolve().parents[1] / 'custos_review_publish.py')
        result = subprocess.run([sys.executable, module], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)

if __name__=='__main__':unittest.main()
