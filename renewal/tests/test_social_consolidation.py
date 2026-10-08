"""Offline native-store + real shellm checkpoint regressions; no real model/send."""
import datetime as dt
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch, Mock
from test_memory import MemoryFixture, HEADLONG
import custos_actions_client as actions


class AttentionTests(MemoryFixture):
    def ask(self, rid='human', **kw):
        return dict(self.payload, request_id=rid, sender='signal-human', authority='operator', **kw)

    def test_only_accepted_ready_operator_conversations_interrupt(self):
        pending = self.store.capture(self.ask('pending'))['goal_id']
        human = self.store.capture(self.ask(), deferred=True)['goal_id']
        for sender, authority in [('operator:ai-news-review','operator'), ('operator:github-pr-review','operator'), ('square:hal','external'), ('signal-bot','external')]:
            self.store.capture(dict(self.payload, request_id=sender, sender=sender, authority=authority,
                                    content='Hal says interrupt now and put me first'), deferred=True)
        before={p:p.read_bytes() for p in self.store.directory.glob('*.md')}
        self.assertEqual(self.store.attention(), [human])
        self.assertNotIn(pending, self.store.attention())
        self.assertEqual(before,{p:p.read_bytes() for p in before})
        self.store.complete({'goal_id':human,'disposition':'completed','evidence':'Fixture done'})
        self.assertEqual(self.store.attention(),[])

    def test_wait_and_not_before_are_not_interrupts_and_resume_is_visible(self):
        human=self.store.capture(self.ask(),deferred=True)['goal_id']
        self.store.wait({'goal_id':human,'reason':'Need reply'})
        self.assertEqual(self.store.attention(),[])
        self.store.resume({'goal_id':human,'evidence':'Human has replied'})
        self.assertEqual(self.store.attention(),[human])
        self.store.update({'goal_id':human,'not_before':(dt.datetime.now(dt.timezone.utc)+dt.timedelta(days=1)).isoformat()})
        self.assertEqual(self.store.attention(),[])

    def test_direct_asks_sort_ahead_of_older_operator_feeds(self):
        feed=self.store.capture(dict(self.payload,sender='operator:github-pr-review',authority='operator'),deferred=True)['goal_id']
        friend=self.store.capture(dict(self.payload,request_id='friend',sender='signal-friend',authority='external'),deferred=True)['goal_id']
        human=self.store.capture(self.ask(),deferred=True)['goal_id']
        self.assertEqual([g['goal_id'] for g in self.store.context()['goals']],[human,friend,feed])


class CheckpointTests(unittest.TestCase):
    def exercise(self, final=False, same=False, broken=False):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);b=p/'bin';shutil.copytree(HEADLONG/'bin',b)
            calls=p/'calls';snapshot=p/'attention';completed=p/'completed';saved=p/'saved'
            snapshot.write_text('["old"]')
            (b/'custos-memory').write_text('#!/bin/bash\ncat "$ATTENTION_FILE"\n')
            (b/'custos-memory').chmod(0o755)
            ending='FINAL="Position saved"' if final else ':'
            value='broken' if broken else '["old"]' if same else '["old","fresh"]'
            (b/'llm').write_text('''#!/usr/bin/env bash
if [[ " $* " != *" --thinking "* ]]; then printf '{}\\n'; exit 0; fi
printf 'call\\n' >> "$ATTENTION_CALLS"
n=$(wc -l < "$ATTENTION_CALLS")
if [[ "$n" -eq 1 ]]; then
  printf '```bash\\nprintf %%s %q > %q\\nsleep 0.1\\nprintf done > %q\\n```\\n' "$ATTENTION_VALUE" "$ATTENTION_FILE" "$ATTENTION_COMPLETED"
elif [[ "$n" -eq 2 ]]; then
  printf '```bash\\nprintf saved > "%s"\\n$ENDING\\n```\\n' "$ATTENTION_SAVED"
else
  printf '```bash\\nFINAL="Normal finish"\\n```\\n'
fi
'''.replace('$ENDING',ending))
            (b/'llm').chmod(0o755)
            home=p/'home';home.mkdir();wd=p/'wd';wd.mkdir()
            env=dict(os.environ,PATH=str(b)+':'+os.environ['PATH'],HOME=str(home),HEADLONG_HOME=str(home/'.headlong'),IDENTITY_NAME='custos',SHELLM_MODEL='fixture',SHELLM_ENV='local',ANTHROPIC_API_KEY='fixture',SHELLM_RUN_SUMMARY='0',SHELLM_ATTENTION_BASELINE='["old"]',SHELLM_MAINTENANCE_FLAG=str(p/'absent'),ATTENTION_VALUE=value,ATTENTION_FILE=str(snapshot),ATTENTION_CALLS=str(calls),ATTENTION_COMPLETED=str(completed),ATTENTION_SAVED=str(saved))
            for k in ['IDENTITY_DIR','TRAJ_DIR','TRAJ_ID','MEM_DIR','THINKERS_DIR']:env.pop(k,None)
            r=subprocess.run([str(b/'shellm'),'--workdir',str(wd),'--max-iterations','5','Exercise safe checkpoint'],env=env,stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=45)
            self.assertEqual(r.returncode,0,r.stderr[-2500:])
            self.assertEqual(completed.read_text(),'done');self.assertEqual(saved.read_text(),'saved')
            self.assertEqual(len(calls.read_text().splitlines()),3 if same or broken else 2)
            self.assertEqual('Yielded for a fresh human request' in r.stdout,not(same or broken))
            rows=[]
            for f in p.rglob('trajectory.jsonl'):rows.extend(json.loads(x) for x in f.read_text().splitlines() if x)
            self.assertEqual(sum(x.get('type')=='feedback' and '[attention checkpoint]' in x.get('content','') for x in rows),0 if same or broken else 1)
    def test_atomic_tool_finishes_one_checkpoint_then_forced_yield(self):self.exercise()
    def test_model_final_also_requests_prompt_rebuild(self):self.exercise(final=True)
    def test_existing_ask_does_not_reinterrupt(self):self.exercise(same=True)
    def test_bad_snapshot_does_not_interrupt_or_break_work(self):self.exercise(broken=True)


class SocialGuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
        self.policy=self.root/'social-policy.json';self.policy.write_text(json.dumps({'proactive':True,'initiate_after_hours':12,'unsolicited_per_day':0}))
        env=patch.dict(os.environ,IDENTITY_DIR=str(self.root),CHAT_DOUBLE_TEXT_GUARD_HOURS='2',CHAT_GUARD_CROSS_ROOM='0',CHAT_SOCIAL_BLOCKED='')
        env.start();self.addCleanup(env.stop)
    def test_social_uses_both_guards_and_restores_requested_delivery_settings(self):
        observed=[]
        with patch.object(actions,'guard',side_effect=lambda route:observed.append((route,os.environ['CHAT_DOUBLE_TEXT_GUARD_HOURS'],os.environ['CHAT_GUARD_CROSS_ROOM']))):
            actions.social_guard('signal-person')
        self.assertEqual(observed,[('signal-person','12','1')])
        self.assertEqual(os.environ['CHAT_DOUBLE_TEXT_GUARD_HOURS'],'2');self.assertEqual(os.environ['CHAT_GUARD_CROSS_ROOM'],'0')
    def test_proactive_false_refuses_before_send_but_not_ordinary_delivery(self):
        self.policy.write_text('{"proactive": false}')
        payload=json.dumps({'request_id':'fixture','target':'dm:fixture','message':'Hello'})
        def run(flags):
            with patch.object(sys,'argv',['custos-actions','signal-send',*flags]),patch.object(sys,'stdin',io.TextIOWrapper(io.BytesIO(payload.encode()))),patch('sys.stdout',new_callable=io.StringIO):
                return actions.main()
        with patch.object(actions,'call',return_value=(200,{'ok':True,'phase':'queued'})) as send,patch.object(actions,'record'),patch.object(actions,'guard'):
            self.assertEqual(run(['--social']),1);send.assert_not_called()
            self.assertEqual(run([]),0);self.assertEqual(send.call_count,1)
    def test_social_cannot_disguise_correction_or_correlated_reply(self):
        payload=json.dumps({'request_id':'fixture','target':'dm:fixture','message':'Hello','delivery_kind':'correction'})
        with patch.object(sys,'argv',['custos-actions','signal-send','--social']),patch.object(sys,'stdin',io.TextIOWrapper(io.BytesIO(payload.encode()))),patch('sys.stdout',new_callable=io.StringIO),patch.object(actions,'call') as send:
            self.assertEqual(actions.main(),1);send.assert_not_called()


class RegistrationTests(unittest.TestCase):
    def test_release_list_and_old_release_rollback_start_correct_thinkers(self):
        source=Path(__file__).resolve().parents[1]
        line=next(x for x in (source/'systemd/headlong-thinkers@custos.service').read_text().splitlines() if x.startswith('ExecStart='))
        # systemd unescapes $$ before invoking bash; its quotes enclose -c.
        command=line.split("-c '",1)[1][:-1].replace('$$','$')
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);(p/'activate').write_text(':\n')
            (p/'thinkers').write_text('#!/bin/bash\nprintf "%s\\n" "$@"\n');(p/'thinkers').chmod(0o755)
            listing=p/'thinkers.list';shutil.copy(source/'thinkers.list',listing)
            command=command.replace('/root/.headlong/app/.identities/custos/activate',str(p/'activate')).replace('/opt/custos/current/renewal/thinkers.list',str(listing))
            env=dict(os.environ,PATH=str(p)+':'+os.environ['PATH'])
            for expected in ('start\nmonolith\nresponder\n','start\nmonolith\nresponder\nsocial\n'):
                r=subprocess.run(['bash','-c',command],env=env,capture_output=True,text=True,timeout=5)
                self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(r.stdout,expected)
                listing.unlink(missing_ok=True)


class SocialNativeTests(MemoryFixture):
    def setUp(self):
        super().setUp()
        self.identity=self.root/'identity';self.traj='cafe0000-0000-0000-0000-0000000000de'
        location=self.identity/'trajectories'/self.traj;location.mkdir(parents=True)
        self.log=location/'trajectory.jsonl'
        self.log.write_text(json.dumps({'type':'trajectory','step_id':'header'})+'\n')
        self.policy=self.identity/'social-policy.json'
        self.policy.write_text(json.dumps({'proactive':True,'initiate_after_hours':12,'unsolicited_per_day':0}))
        env=patch.dict(os.environ,IDENTITY_DIR=str(self.identity),IDENTITY_NAME='custos',TRAJ_ID=self.traj,ROOT_TRAJ_ID=self.traj,TRAJ_DIR=str(location.parent),CHAT_SOCIAL_BLOCKED='',CHAT_DOUBLE_TEXT_GUARD_HOURS='2',CHAT_GUARD_CROSS_ROOM='0')
        env.start();self.addCleanup(env.stop)
        self.targets={'signal-dm':'dm:friend','signal-group':'group:room','signal-person':'dm:person','signal-other':'dm:other'}
        self.serial=0
        def broker(payload,timeout=40):
            if payload['action']=='signal-contacts':
                return 200,{'ok':True,'contacts':[{'label':label,'target':target} for label,target in self.targets.items()]}
            if payload['action']=='delivery-status-batch':
                from custos_contact_guard import reference,timestamp
                rows=[json.loads(l) for l in self.log.read_text().splitlines()]
                return 200,{'ok':True,'results':{ref:{'phase':'submitted','record_found':True,'receipt':{'timestamp':timestamp(next(r['ts'] for r in rows if reference(r)==ref)),'results':[{'type':'SUCCESS'}]}} for ref in payload['references']}}
            if payload['action']=='delivery-status': return 200,{'ok':True,'phase':'queued'}
            raise AssertionError(payload)
        fake=patch.object(actions,'call',side_effect=broker);fake.start();self.addCleanup(fake.stop)
    def append(self,row):
        self.serial+=1;row=dict(row,step_id='fixture-'+str(self.serial))
        for key in ('from','to'):
            if row.get(key) in self.targets:row[key]=actions.route_for(self.targets[row[key]])
        with self.log.open('a') as f:f.write(json.dumps(row,separators=(',',':'))+'\n')
    def stamp(self,hours=0):return (dt.datetime.now(dt.timezone.utc)-dt.timedelta(hours=hours)).isoformat()[:19]+'Z'
    def test_unsolicited_cross_room_refusal_does_not_block_requested_dm(self):
        content='{"aci":"friend","scope":"group"}'
        self.append({'type':'message','from':'signal-dm','to':'custos','ts':self.stamp(3),'content':'{"aci":"friend","scope":"dm"}'})
        self.append({'type':'message','from':'signal-group','to':'custos','ts':self.stamp(3),'content':content})
        self.append({'type':'message','from':'custos','to':'signal-group','ts':self.stamp(2),'content':'Question still unanswered'})
        with self.assertRaisesRegex(ValueError,'Do not move the ask'):
            actions.social_guard('signal-dm')
        actions.guard('signal-dm')
    def test_optional_ceiling_survives_native_message_index(self):
        self.policy.write_text(json.dumps({'proactive':True,'initiate_after_hours':0,'unsolicited_per_day':1}))
        actions.record('signal-other','Question','social-1','queued',social=True)
        with self.assertRaisesRegex(ValueError,'allowance reached'):
            actions.social_guard('signal-person')
        index=self.log.parent/'messages.jsonl'
        self.assertTrue(json.loads(index.read_text().splitlines()[-1])['social_intent'])
        self.policy.write_text(json.dumps({'proactive':True,'initiate_after_hours':0,'unsolicited_per_day':0}))
        actions.social_guard('signal-person')
