"""Dream safety and lifecycle behavior; temporary identities, no inference/network."""
import datetime as dt
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import sys
import subprocess
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import custos_dream as d
import custos_memory as cm
from test_memory import MemoryFixture

class DreamTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.store=cm.Store(self.root/'memories')
        self.env=mock.patch.dict(os.environ,{'TRAJ_ID':'','IDENTITY_DIR':str(self.root)})
        self.env.start();self.addCleanup(self.env.stop)
        self.now=dt.datetime(2026,9,10,9,30,tzinfo=dt.timezone.utc)
        self.d=d.Dream(self.store,clock=lambda:self.now)
        self.put('11111111','Fact A');self.put('22222222','Fact B')
    def put(self,key,body,kind='fact'):
        p=self.store.directory/(key+'.md')
        p.write_text('---\nid: '+key+'\ntype: '+kind+'\ncreated: 2026-09-09 00:00:00\nsummary: Fact\n---\n\n'+body+'\n')
        return d.sha(p.read_bytes())
    def digest(self,key):return d.sha(self.store.find(key)[0].read_bytes())
    def test_window_and_once_per_local_day(self):
        self.now-=dt.timedelta(seconds=1);self.assertEqual(self.d.due(),'')
        self.now+=dt.timedelta(seconds=1);self.assertIn('dream',self.d.due())
        self.d.begin();self.d.finish('Partial is honest');self.assertEqual(self.d.due(),'')
        self.now+=dt.timedelta(days=1);self.assertIn('dream',self.d.due())
    def test_dst_uses_denver_calendar(self):
        self.now=dt.datetime(2026,11,1,10,30,tzinfo=dt.timezone.utc)
        self.assertTrue(self.d.window());self.assertEqual(self.d.day(),'2026-11-01')
        self.d.begin();self.d.finish('done');self.assertEqual(self.d.due(),'')
    def test_disabled_and_missed_window_do_not_start(self):
        self.d.config['enabled']=False;self.assertEqual(self.d.due(),'')
        self.d.config['enabled']=True;self.now+=dt.timedelta(hours=2)
        self.assertEqual(self.d.due(),'');self.assertFalse(self.d.session_path().exists())
        with self.assertRaises(ValueError):self.d.begin()
    def test_expiry_after_window_and_across_midnight_leaves_original_report(self):
        self.d.begin();day=self.d.day();self.now+=dt.timedelta(days=1,hours=2)
        self.assertEqual(self.d.due(),'')
        old=d.read_json(self.d.root/day/'session.json');self.assertEqual(old['status'],'expired')
        self.assertTrue((self.d.root/day/'report.md').exists());self.assertFalse(self.d.session_path().exists())
    def test_deadline_prevents_edit(self):
        self.d.begin();self.now+=dt.timedelta(minutes=20)
        with self.assertRaises(ValueError):self.d.revise('11111111',self.digest('11111111'),'B','source')
        self.d.due();self.assertEqual(d.read_json(self.d.session_path())['status'],'expired')
    def test_cas_preserves_concurrent_change(self):
        self.d.begin();old=self.digest('11111111');self.put('11111111','New source')
        with self.assertRaises(ValueError):self.d.revise('11111111',old,'Lost update','source')
        self.assertEqual(self.store.find('11111111')[2],'New source')
        self.assertEqual(list((self.d.root/self.d.day()/'changes').glob('*')),[])
    def test_revision_backup_and_keep_uncertain_rotation(self):
        self.d.begin();p=self.store.find('11111111')[0];raw=p.read_bytes()
        e=self.d.revise('11111111',d.sha(raw),'Verified fact','artifact X')
        self.assertEqual(Path(e['backup']).read_bytes(),raw)
        self.assertEqual(Path(e['backup']).stat().st_mode&0o777,0o600)
        self.d.review('11111111',e['after_sha256'],'revised','artifact X')
        self.d.review('22222222',self.digest('22222222'),'uncertain','conflicting sources')
        self.assertEqual(self.d.finish('Both reviewed')['status'],'complete')
        self.now+=dt.timedelta(days=1);self.put('33333333','New question')
        self.assertEqual(self.d.begin()['selected'][0]['id'],'33333333')
    def decisions(self):
        return [{'id': key, 'expected': self.digest(key), 'verdict': 'keep',
                 'evidence': 'Read full fact and checked source ' + key} for key in ['11111111','22222222']]

    def test_batch_records_decisions_and_preview_does_not_close(self):
        self.d.begin()
        preview=self.d.finish_preview()
        self.assertEqual(preview['reviewed'],0)
        self.assertEqual(set(preview['missing']),{'11111111','22222222'})
        self.assertTrue(preview['can_continue'])
        self.d.review_batch(self.decisions())
        self.assertEqual(self.d.finish_preview()['finish_status'],'complete')
        self.assertEqual(len(d.read_json(self.d.root/'reviewed.json')),2)
        self.assertEqual(self.d.finish('evidence recorded')['reviewed'],2)
        with self.assertRaisesRegex(ValueError,'no active dream'):
            self.d.review_batch(self.decisions())

    def test_invalid_batch_is_rejected_without_partial_decisions(self):
        self.d.begin()
        for replacement in [{'expected':'0'*64}, {'evidence':''}, {'verdict':'invented'},
                            {'id':'33333333'}, {'expected':None}, {'verdict':[]}]:
            rows=self.decisions();rows[1].update(replacement)
            with self.assertRaises(ValueError):self.d.review_batch(rows)
            self.assertEqual(d.read_json(self.d.session_path())['reviews'],{})
            self.assertFalse((self.d.root/'reviewed.json').exists())
        row=self.decisions()[0]
        with self.assertRaisesRegex(ValueError,'duplicate'):self.d.review_batch([row,row])
        self.d.config['batch_size']=1
        with self.assertRaises(ValueError):self.d.review_batch(self.decisions())

    def test_batch_current_hash_and_revision_receipt_required(self):
        self.d.begin();rows=self.decisions()
        change=self.d.revise('11111111',rows[0]['expected'],'Corrected fact','primary source')
        rows[0]['verdict']='revised'
        with self.assertRaisesRegex(ValueError,'changed'):self.d.review_batch(rows)
        rows[0]['expected']=change['after_sha256'];rows[1]['verdict']='revised'
        with self.assertRaisesRegex(ValueError,'no revision receipt'):self.d.review_batch(rows)
        rows[1]['verdict']='uncertain';self.d.review_batch(rows)
        self.assertEqual(self.d.finish_preview()['missing'],[])

    def test_partial_preview_and_expired_budget_never_manufacture_reviews(self):
        self.d.begin();self.d.review_batch(self.decisions()[:1])
        self.now+=dt.timedelta(minutes=20)
        self.assertFalse(self.d.finish_preview()['can_continue'])
        with self.assertRaises(ValueError):self.d.review_batch(self.decisions()[1:])
        result=self.d.finish('Only one record reviewed')
        self.assertEqual((result['status'],result['reviewed'],result['remaining']),('partial',1,1))

    def test_protected_identity_values_and_goals(self):
        self.put('33333333','Value','value');self.put('44444444','Active objective','objective')
        meta={'person_key':'hal','display':'Hal','aliases':[],'routes':['hal']}
        self.put('55555555','Person: Hal\n\nNotes'+cm.PERSON_MARKER+json.dumps(meta),'person')
        self.d.begin()
        for key in ['33333333','44444444','55555555']:
            with self.assertRaises(ValueError):self.d.revise(key,self.digest(key),None,'source',True,'11111111')
        with self.assertRaises(ValueError):self.d.revise('33333333',self.digest('33333333'),'New value','source')
        meta['routes']=['attacker']
        with self.assertRaises(ValueError):self.d.revise('55555555',self.digest('55555555'),'Person: Hal'+cm.PERSON_MARKER+json.dumps(meta),'source')
    def test_archive_requires_canonical_and_still_readable(self):
        self.d.begin();before=self.digest('11111111')
        with self.assertRaises(ValueError):self.d.revise('11111111',before,None,'duplicate',True)
        e=self.d.revise('11111111',before,None,'same fact as 22222222',True,'22222222')
        self.assertFalse(Path(e['source']).exists());self.assertTrue(Path(e['target']).exists())
        self.d.review('11111111',e['after_sha256'],'archived','canonical 22222222')
    def test_crash_after_write_reconciles_and_consumes_budget(self):
        self.d.config['max_edits']=1;self.d.begin();real=d.write_json
        def crash(path,value):
            if path.parent.name=='changes' and value.get('status')=='applied':raise OSError('simulated power loss')
            return real(path,value)
        with mock.patch.object(d,'write_json',side_effect=crash):
            with self.assertRaises(OSError):self.d.revise('11111111',self.digest('11111111'),'Changed','source')
        active=self.d.active();self.assertEqual(len(active['edits']),1)
        self.assertEqual(d.read_json(Path(active['edits'][0]))['status'],'applied')
        with self.assertRaises(ValueError):self.d.revise('22222222',self.digest('22222222'),'Extra','source')
        self.d.review('11111111',self.digest('11111111'),'revised','source')
    def test_prepared_not_applied_is_not_revision_evidence(self):
        self.d.begin()
        with mock.patch.object(d,'atomic',side_effect=OSError('disk full')):
            with self.assertRaises(OSError):self.d.revise('11111111',self.digest('11111111'),'Changed','source')
        with self.assertRaises(ValueError):self.d.review('11111111',self.digest('11111111'),'revised','source')

class LifecycleTests(MemoryFixture):
    def test_native_edit_waits_for_reviewer_lock(self):
        key=self.store.commit("Original fact",memory_type="fact")
        with self.store.lock():
            proc=subprocess.Popen([self.native_mem,"--dir",str(self.store.directory),"edit",key,"Fresh fact"],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                with self.assertRaises(subprocess.TimeoutExpired):proc.communicate(timeout=0.2)
                self.assertEqual(self.store.find(key)[2],"Original fact")
            except BaseException:
                proc.kill();proc.communicate();raise
        stdout,stderr=proc.communicate(timeout=5)
        self.assertEqual(proc.returncode,0,stderr)
        self.assertEqual(self.store.find(key)[2],"Fresh fact")

    def age(self,key):
        with self.store.lock():
            item=self.store.find(key);item[4]['received_at']='2026-01-01T00:00:00+00:00';self.store.save(item,item[4])
    def test_only_untouched_ambient_settles(self):
        keys=[]
        for i in range(4):
            p={**self.payload,'request_id':str(i)}
            if i!=1:p['ambient']=True
            key=self.store.capture(p)['goal_id'];keys.append(key);self.age(key)
        with self.store.lock():
            item=self.store.find(keys[2]);item[4]['responder_attempt']={'state':'failed'};self.store.save(item,item[4])
        item=self.store.find(keys[3]);item[4]['response']={'state':'sent','plan':{'decision':'defer','goal':item[4]['goal']}};self.store.save(item,item[4])
        self.assertEqual(self.store.settle_ambient(),1)
        self.assertEqual(self.store.find(keys[0])[4]['status'],'completed')
        self.assertTrue(all(self.store.find(k)[4]['status']=='active' for k in keys[1:]))
        self.assertEqual(self.store.settle_ambient(),0)
    def test_fresh_ambient_is_not_expired(self):
        self.store.capture({**self.payload,'ambient':True})
        self.assertEqual(self.store.settle_ambient(),0)
    def test_structured_origin_status_and_archive_protected(self):
        key=self.store.capture(self.payload)['goal_id']
        dream=d.Dream(self.store,clock=lambda:dt.datetime(2026,9,10,9,30,tzinfo=dt.timezone.utc))
        # Ordinary unattempted directed receipt is a conversation; flag explicitly
        # by using a real deferred goal, just as production's semantic batch does.
        item=self.store.find(key);item[4]['response']={'state':'sent','plan':{'decision':'defer','goal':item[4]['goal']}};self.store.save(item,item[4])
        dream.begin();item=self.store.find(key);body=item[2];digest=d.sha(item[0].read_bytes())
        with self.assertRaises(ValueError):dream.revise(key,digest,body.replace('agent','operator'),'bad source')
        with self.assertRaises(ValueError):dream.revise(key,digest,None,'old',True,'11111111')
        e=dream.revise(key,digest,'Current evidence incomplete; retain historical receipt.\n\n'+body,'audit')
        self.assertEqual(self.store.find(key)[4],item[4])

if __name__=='__main__':unittest.main()

class TrajectoryAuditTests(MemoryFixture):
    def test_audit_reads_a_day_and_names_problems(self):
        root=self.root;store=self.store
        env=mock.patch.dict(os.environ,{'IDENTITY_DIR':str(root),'IDENTITY_NAME':'custos'});env.start();self.addCleanup(env.stop)
        now=dt.datetime(2026,9,12,9,45,tzinfo=dt.timezone.utc);dr=d.Dream(store,root=root/'dream',clock=lambda:now)  # 03:45 Denver: inside the dream window for begin/finish
        t='2026-09-12T0'
        rows=[{"type":"shellm-run","step_id":"r1","launched_by":"monolith","ts":t+"1:00:00Z"},
              {"type":"reasoning","run_id":"r1","ts":t+"1:00:10Z"},{"type":"reasoning","run_id":"r1","ts":t+"1:00:20Z"},{"type":"run-end","run_id":"r1","rc":1,"ts":t+"1:01:00Z"},
              {"type":"shellm-run","step_id":"r2","launched_by":"monolith","ts":t+"2:00:00Z"},
              {"type":"reasoning","run_id":"r2","ts":t+"2:00:10Z"},{"type":"observation","run_id":"r2","source":"monolith","content":"did a thing","ts":t+"2:00:20Z"},{"type":"run-end","run_id":"r2","rc":0,"ts":t+"2:01:00Z"},
              {"type":"message","from":"custos","to":"signal-a9","source":"responder","reply_to":"x","content":"I'll add it to the list.","ts":t+"3:00:00Z"},
              {"type":"observation","source":"social","content":"not sent: the guard refused a second message","ts":t+"4:00:00Z"},
              {"type":"shell-output","run_id":"r2","stdout":"Helper returned nonzero; inspect retained report","ts":t+"5:00:00Z"},
              {"type":"reasoning","run_id":"old","ts":"2026-09-10T01:00:00Z"}]
        traj=root/'trajectory.jsonl';traj.write_text("\n".join(json.dumps(r,separators=(",",":")) for r in rows)+"\n")  # compact, like traj append writes
        gid=store.capture({"request_id":"signal:1","sender":"signal-a9","source_url":"signal:1","authority":"operator",
                           "content":'x\n{"speaker":"Dani","group":"Collette Haus","scope":"group"}\nMessage:\nAdd a jar of tahini\nParticipation: y'},"tr")["goal_id"]
        item=store.find(gid);rec=item[4]
        rec["response"]={"state":"sent","plan":{"reply":"ok","decision":"defer","goal":rec["goal"],"memories":[]}}
        rec["received_at"]=(now-dt.timedelta(hours=8)).isoformat();store.save(item,rec)
        out=dr.audit(hours=24,path=traj)
        self.assertEqual(out["runs"]["monolith"]["runs"],2);self.assertEqual(out["runs"]["monolith"]["rc_nonzero"],1);self.assertEqual(out["runs"]["monolith"]["no_durable"],1)
        kinds={p["kind"] for p in out["problems"]}
        self.assertEqual(kinds,{"wasted-wakes","untouched-ask","promise-in-reply","failed-send","helper-failure"})  # 1 of 2 runs had no durable step
        ua=[p for p in out["problems"] if p["kind"]=="untouched-ask"][0];self.assertEqual(ua["goal_id"],gid);self.assertTrue(ua["quick"])
        self.assertEqual(out["counts"]["responder_replies"],1)
        self.assertTrue((dr.root/dr.day()/'audit.json').exists())
        # finish folds the audit into the report
        dr.begin();r=dr.finish('done');self.assertIn('Trajectory audit',(dr.root/dr.day()/'report.md').read_text())
        self.assertIn('untouched-ask',(dr.root/dr.day()/'report.md').read_text())

class AuditAccountingTests(MemoryFixture):
    def test_recorded_cap_maintenance_final_only_and_incomplete(self):
        now=dt.datetime(2026,9,16,9,45,tzinfo=dt.timezone.utc)
        dr=d.Dream(self.store,clock=lambda:now)
        rows=[]
        def add(run,steps,cap=None,rc=0,extra=None):
            start={'type':'shellm-run','step_id':run,'launched_by':'monolith','ts':'2026-09-16T08:00:00Z'}
            if cap is not None:start['max_iterations']=cap
            rows.append(start)
            rows.extend({'type':'reasoning','run_id':run,'ts':'2026-09-16T08:01:00Z'} for _ in range(steps))
            if extra:rows.append(dict(extra,run_id=run,ts='2026-09-16T08:02:00Z'))
            if rc is not None:rows.append({'type':'run-end','run_id':run,'rc':rc,'ts':'2026-09-16T08:03:00Z'})
        add('below-real-cap',44,150,extra={'type':'final','content':'done'})
        add('at-recorded-cap',3,3,rc=1)
        add('fallback',44,extra={'type':'thought','content':'useful'})
        add('maintenance',5,150,rc=1,extra={'type':'feedback','content':'[harness maintenance] yield'})
        add('handoff',0,150,extra={'type':'harness-handoff','content':'Yielded for harness maintenance'})
        add('incomplete',7,150,rc=None)
        add('zero-failure',0,150,rc=1)
        add('unknown-cap',2,'invalid',extra={'type':'final','content':'done'})
        traj=self.root/'audit.jsonl';traj.write_text('\n'.join(json.dumps(r) for r in rows))
        with mock.patch.dict(os.environ,{'SHELLM_MAX_ITERATIONS':'150','MONOLITH_MAX_ITERATIONS':'40'}):
            result=dr.audit(path=traj)
        m=result['runs']['monolith']
        self.assertEqual(m['runs'],8);self.assertEqual(m['at_cap'],1)
        self.assertEqual(m['maintenance_interrupted'],2)
        self.assertEqual(m['rc_nonzero'],3);self.assertEqual(m['failures'],2)
        self.assertEqual(m['incomplete'],1);self.assertEqual(m['final_only'],2)
        self.assertEqual(m['no_durable'],2)
        details={r['run_id']:r for r in result['run_details']}
        self.assertEqual(details['fallback']['cap_source'],'current-environment-estimate')
        self.assertIsNone(details['unknown-cap']['cap'])

class CriticalSelectionTests(unittest.TestCase):
    setUp = DreamTests.setUp
    put = DreamTests.put
    digest = DreamTests.digest
    def test_critical_claim_gets_reserved_space_without_starving_rotation(self):
        self.d.config['batch_size']=2
        self.put('ffffffff','Correction: causal mechanism is uncertain; compare source B')
        selected=self.d.begin()['selected']
        self.assertEqual(selected[0]['id'],'ffffffff')
        self.assertEqual(selected[1]['id'],'11111111')
        self.d.review_batch([{'id':'ffffffff','expected':self.digest('ffffffff'),'verdict':'uncertain',
                              'evidence':'Source A is associative','counterevidence':'Source B tests the mechanism and fails'}])
        review=d.read_json(self.d.session_path())['reviews']['ffffffff']
        self.assertIn('Source B',review['counterevidence'])


class DeliverySupersededTests(MemoryFixture):
    """cbc2030a: a blocked ref is not a contradiction when a later ref for the
    same goal carries a confirmed submission (the batch that followed delivered)."""

    def _dream(self, now):
        env = mock.patch.dict(os.environ, {'IDENTITY_DIR': str(self.root), 'IDENTITY_NAME': 'custos'})
        env.start(); self.addCleanup(env.stop)
        return d.Dream(self.store, root=self.root / 'dream', clock=lambda: now)

    def _traj(self, rows):
        p = self.root / 'trajectory.jsonl'
        p.write_text("\n".join(json.dumps(r, separators=(",", ":")) for r in rows) + "\n")
        return p

    def _batch(self, results):
        def fake_call(payload, timeout=40):
            return 200, {'ok': True, 'results': {r: results.get(r, {'phase': 'unknown'}) for r in payload['references']}}
        return mock.patch('custos_actions_client.call', side_effect=fake_call)

    def test_blocked_ref_superseded_by_later_submitted_same_goal(self):
        now = dt.datetime(2026, 10, 16, 9, 45, tzinfo=dt.timezone.utc)
        dr = self._dream(now)
        t = '2026-10-16T'
        rows = [
            {"type": "message", "from": "custos", "to": "signal-hal", "step_id": "s1", "goal_id": "g1", "content": "digest part 1", "ts": t + "00:14:00Z"},
            {"type": "message", "from": "custos", "to": "signal-hal", "step_id": "s2", "goal_id": "g1", "content": "digest tail", "ts": t + "00:16:00Z"},
            {"type": "message", "from": "custos", "to": "signal-hal", "step_id": "s3", "goal_id": "g1", "content": "digest v2", "ts": t + "00:48:00Z"},
            {"type": "message", "from": "custos", "to": "signal-hal", "step_id": "s4", "goal_id": "g2", "content": "orphan", "ts": t + "01:00:00Z"},
        ]
        traj = self._traj(rows)
        submitted = {'phase': 'submitted', 'receipt': {'timestamp': 1792111713873, 'results': [{'type': 'SUCCESS'}], 'converted_to_reaction': False}}
        blocked = {'phase': 'blocked', 'receipt': {'timestamp': 1792100000000, 'results': [{'type': 'BLOCKED'}], 'converted_to_reaction': False}}
        with self._batch({'outbox:s1': blocked, 'outbox:s2': blocked, 'outbox:s3': submitted, 'outbox:s4': blocked}):
            issues = dr.delivery_issues(hours=24, path=traj)
        flagged = {i['reference'] for i in issues}
        self.assertNotIn('outbox:s1', flagged)  # superseded by s3 (submitted, g1, later)
        self.assertNotIn('outbox:s2', flagged)  # superseded by s3
        self.assertNotIn('outbox:s3', flagged)  # submitted
        self.assertIn('outbox:s4', flagged)     # blocked, g2, no later submitted ref
        self.assertEqual(len(issues), 1)
        self.assertEqual(issues[0]['goal_id'], 'g2')

    def test_blocked_ref_postdating_only_submission_is_still_flagged(self):
        # A blocked ref is only superseded by a LATER submission. If it postdates
        # the only submission for its goal, it is still a problem.
        now = dt.datetime(2026, 10, 16, 9, 45, tzinfo=dt.timezone.utc)
        dr = self._dream(now)
        t = '2026-10-16T'
        rows = [
            {"type": "message", "from": "custos", "to": "signal-hal", "step_id": "s1", "goal_id": "g1", "content": "digest v1", "ts": t + "00:48:00Z"},
            {"type": "message", "from": "custos", "to": "signal-hal", "step_id": "s2", "goal_id": "g1", "content": "resend after block", "ts": t + "01:00:00Z"},
        ]
        traj = self._traj(rows)
        submitted = {'phase': 'submitted', 'receipt': {'timestamp': 1792111713873, 'results': [{'type': 'SUCCESS'}], 'converted_to_reaction': False}}
        blocked = {'phase': 'blocked', 'receipt': {'timestamp': 1792100000000, 'results': [{'type': 'BLOCKED'}], 'converted_to_reaction': False}}
        with self._batch({'outbox:s1': submitted, 'outbox:s2': blocked}):
            issues = dr.delivery_issues(hours=24, path=traj)
        flagged = {i['reference'] for i in issues}
        self.assertNotIn('outbox:s1', flagged)  # submitted
        self.assertIn('outbox:s2', flagged)     # blocked, postdates the only submission -> not superseded
        self.assertEqual(len(issues), 1)


class FailedSendProseTests(MemoryFixture):
    """cbc2030a: 'Not sent yet.' is a parked/staged message, not a failed send."""

    def _dream(self, now):
        env = mock.patch.dict(os.environ, {'IDENTITY_DIR': str(self.root), 'IDENTITY_NAME': 'custos'})
        env.start(); self.addCleanup(env.stop)
        return d.Dream(self.store, root=self.root / 'dream', clock=lambda: now)

    def _traj(self, rows):
        p = self.root / 'trajectory.jsonl'
        p.write_text("\n".join(json.dumps(r, separators=(",", ":")) for r in rows) + "\n")
        return p

    def test_parked_not_sent_yet_is_not_a_failed_send(self):
        now = dt.datetime(2026, 10, 16, 9, 45, tzinfo=dt.timezone.utc)
        dr = self._dream(now)
        t = '2026-10-16T'
        rows = [
            {"type": "observation", "source": "monolith", "content": "Staged as ainews-a19e5d39 for the 14:06:51Z batch boundary. Not sent yet.", "ts": t + "09:25:00Z"},
        ]
        traj = self._traj(rows)
        out = dr.audit(hours=24, path=traj)
        self.assertEqual([p for p in out['problems'] if p['kind'] == 'failed-send'], [])

    def test_guard_refusal_is_still_a_failed_send(self):
        now = dt.datetime(2026, 10, 16, 9, 45, tzinfo=dt.timezone.utc)
        dr = self._dream(now)
        t = '2026-10-16T'
        rows = [
            {"type": "observation", "source": "social", "content": "not sent: the guard refused a second message", "ts": t + "09:25:00Z"},
        ]
        traj = self._traj(rows)
        out = dr.audit(hours=24, path=traj)
        self.assertEqual(len([p for p in out['problems'] if p['kind'] == 'failed-send']), 1)
