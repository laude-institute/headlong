import datetime as dt
"""Regressions from the 2026-09-24 audit, executed only in a disposable fixture."""
import io,json,os,shutil,subprocess,sys,tempfile,time,unittest
from pathlib import Path
from unittest.mock import patch,Mock
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import custos_evidence as evidence
import custos_publication_evidence as publication
import custos_actions_client as client
import custos_memory as memory
from harness import seal
from test_memory import MemoryFixture

class Numbers(unittest.TestCase):
    def claim(self,variant,field,value,unit='USD/M tokens'):
        return {'variant':variant,'field':field,'value':value,'unit':unit,
                'sources':[{'url':'https://example.org/primary','quote':f'{variant} {field}: {value} {unit}','primary':True}]}
    def test_price_arrow_and_named_baseline(self):
        claims=[];comparisons=[]
        for field,old,new in [('input',5,4),('output',25,20),('cache',0.5,0.2)]:
            claims += [self.claim('Opus 5',field,old),self.claim('Opus 5.5',field,new)]
            comparisons.append({'field':field,'old_variant':'Opus 5','new_variant':'Opus 5.5','direction':'decrease'})
        result=evidence.validate({'claims':claims,'comparisons':comparisons})
        self.assertEqual([round(x['change_percent']) for x in result['comparisons']],[-20,-20,-60])
        self.assertIn('Opus 5 5 → Opus 5.5 4 USD/M tokens',result['comparisons'][0]['rendered'])
        comparisons[0]['old_variant'],comparisons[0]['new_variant']='Opus 5.5','Opus 5'
        with self.assertRaisesRegex(ValueError,'direction'):evidence.validate({'claims':claims,'comparisons':comparisons})
    def test_mismatched_units_and_missing_baseline_fail(self):
        claims=[self.claim('old','input',5),self.claim('new','input',4,'USD/K tokens')]
        c={'field':'input','old_variant':'old','new_variant':'new'}
        with self.assertRaisesRegex(ValueError,'units'):evidence.validate({'claims':claims,'comparisons':[c]})
        with self.assertRaises(KeyError):evidence.validate({'claims':claims,'comparisons':[{**c,'old_variant':'Fable'}]})

class Publication(unittest.TestCase):
    def setUp(self):
        self.row={'id':42,'commit_id':'a'*40,'html_url':'https://github.com/o/r/pull/9#pullrequestreview-42',
                  'user':{'login':'custos-1f916'},'state':'COMMENTED','submitted_at':'2026-09-23T00:00:00Z'}
    def capture(self,row):
        with patch.object(publication.subprocess,'run',return_value=Mock(stdout=json.dumps(row))) as run:
            result=publication.capture('o/r',9,'a'*40,42)
            self.assertEqual(run.call_args.args[0],['gh','api','repos/o/r/pulls/9/reviews/42'])
            return result
    def test_comment_never_becomes_approval(self):
        self.assertIn('COMMENT review',self.capture(self.row)['rendered'])
        self.assertIn('APPROVED',self.capture({**self.row,'state':'APPROVED'})['rendered'])
    def test_wrong_head_author_pr_and_draft_are_rejected(self):
        for fields in [{'commit_id':'b'*40},{'user':{'login':'someone-else'}},{'html_url':self.row['html_url'].replace('/9#','/10#')},{'state':'PENDING'},{'submitted_at':None}]:
            with self.assertRaises(ValueError):self.capture({**self.row,**fields})

class SetupCleanup(unittest.TestCase):
    def setUp(self):
        # Unit-test setup failures without requiring nested KVM memory headroom.
        fake=lambda x: Mock(read_text=lambda: 'MemAvailable: 4194304 kB\n') if str(x)=='/proc/meminfo' else Path(x)
        patcher=patch.object(seal,'P',side_effect=fake);patcher.start();self.addCleanup(patcher.stop)

    def test_partial_snapshot_writes_receipt_and_retains_source_and_locks(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);source=root/'source';source.mkdir()
            def fail(src,dest,profile):
                (dest/'source.py').write_text('retained');(dest/'package-lock.json').write_text('lock')
                (dest/'node_modules').mkdir();(dest/'node_modules'/'dependency').write_bytes(b'X'*20000)
                raise ValueError('input bound exceeded')
            with patch.object(seal.shutil,'which',return_value='/fixture/tool'),patch.object(seal,'snapshot',side_effect=fail):
                result=seal._run(source,['true'],job_root=root/'jobs',keep=False)
            job=Path(result['job'])
            self.assertEqual(result['exit_code'],125);self.assertEqual(result['stage'],'snapshot')
            self.assertTrue((job/'setup.json').exists());self.assertEqual(json.loads((job/'result.json').read_text()),result)
            self.assertEqual((job/'input/source.py').read_text(),'retained')
            self.assertEqual((job/'input/package-lock.json').read_text(),'lock')
            self.assertFalse((job/'input/node_modules').exists());self.assertTrue(source.exists())
    def test_cleanup_never_follows_dependency_symlinks(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);outside=root/'outside';outside.mkdir();(outside/'valuable').write_text('keep')
            copied=root/'input';copied.mkdir();(copied/'node_modules').symlink_to(outside,target_is_directory=True)
            self.assertEqual(seal.clean_dependencies(copied),[]);self.assertEqual((outside/'valuable').read_text(),'keep')
    def test_copy_oserror_and_interrupt_are_receipted(self):
        with tempfile.TemporaryDirectory() as d:
            with patch.object(seal.shutil,'which',return_value='/fixture/tool'):
                for error in [OSError('copy failed'),InterruptedError('cancelled')]:
                    with patch.object(seal,'snapshot',side_effect=error):
                        result=seal._run(d,['true'],job_root=Path(d)/'jobs')
                    self.assertEqual(result['exit_code'],125);self.assertTrue(Path(result['job'],'result.json').exists())

class Cooldown(MemoryFixture):
    def test_local_refusal_parks_same_request_and_waits_without_retries(self):
        goal=self.store.capture(self.payload,'trigger',deferred=True)['goal_id']
        identity=self.root/'identity';identity.mkdir()
        payload={'request_id':'one-stable-id','target':'Hal','message':'checked news'}
        with patch.dict(os.environ,{'IDENTITY_DIR':str(identity)}),patch.object(memory,'Store',return_value=self.store):
            result=client.park_cooldown(goal,payload,'dm:fixed',False,client.GuardRefusal({'reason':'cooldown','resume_at':(dt.datetime.now(dt.timezone.utc)+dt.timedelta(hours=2)).isoformat(),'error':'you spoke last'}))
            self.assertEqual(result['goal_id'],goal)
            self.assertEqual(self.store.find(goal)[4]['waiting']['signal_target'],'dm:fixed')
            staged=list((identity/'.state/staged-signal').glob('*.json'));self.assertEqual(len(staged),1)
            self.assertEqual(json.loads(staged[0].read_text()),payload)
            with self.assertRaisesRegex(ValueError,'different payload'):
                client.park_cooldown(goal,{**payload,'message':'changed'},'dm:fixed',False,client.GuardRefusal({'reason':'cooldown','resume_at':(dt.datetime.now(dt.timezone.utc)+dt.timedelta(hours=2)).isoformat(),'error':'you spoke last'}))
        wait=self.store.find(goal)[4]['waiting']
        with patch.object(client,'mind_guard',side_effect=ValueError('you spoke last')),patch.object(client,'call') as call:
            for _ in range(3):self.assertIsNone(memory.wait_event(wait))
            call.assert_not_called()
        with patch.object(client,'mind_guard'),patch.object(client,'call',return_value=(200,{'ok':True,'blocked':False})):
            self.assertIn('eligible',memory.wait_event(wait))
    def test_unknown_refusal_does_not_park_or_send(self):
        self.assertIsNone(client.park_cooldown('anything',{},'dm:fixed',False,'permission denied'))

class ShellRuntime(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
        source=Path(os.environ.get('HEADLONG_ROOT',Path(__file__).resolve().parents[2]/'runtime/headlong'))
        self.b=self.root/'bin';shutil.copytree(source/'bin',self.b)
        self.home=self.root/'home';self.home.mkdir();self.wd=self.root/'wd';self.wd.mkdir()
        self.env={'PATH':str(self.b)+':/usr/local/bin:/usr/bin:/bin','HOME':str(self.home),
                  'HEADLONG_HOME':str(self.home/'.headlong'),'SHELLM_MODEL':'fixture','SHELLM_ENV':'local',
                  'SHELLM_RUN_SUMMARY':'0','SHELLM_MAX_ITERATIONS':'1','ANTHROPIC_API_KEY':'fixture',
                  'SHELLM_INACTIVITY_TIMEOUT':'30','SHELLM_EXEC_TIMEOUT':'3'}
    def stub(self,text):
        response=self.root/'response';response.write_text(text)
        (self.b/'llm').write_text('#!/bin/sh\ncat '+str(response)+'\n');(self.b/'llm').chmod(0o755)
    def rows(self):
        return [json.loads(line) for p in self.home.rglob('trajectory.jsonl') for line in p.read_text().splitlines() if line]
    def test_output_cannot_renew_deadline_and_intent_precedes_execution(self):
        self.stub('Reasoning\n```bash\nprintf started > started\nwhile :; do echo working; sleep 0.1; done\n```\n')
        with subprocess.Popen([str(self.b/'shellm'),'-q','--workdir',str(self.wd),'test deadline'],env=self.env,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) as proc:
            deadline=time.monotonic()+15
            while not (self.wd/'started').exists() and proc.poll() is None and time.monotonic()<deadline:time.sleep(.05)
            reasoning=[r for r in self.rows() if r.get('execution_started')]
            self.assertEqual(len(reasoning),1);self.assertIn('while :',reasoning[0]['cmd'])
            self.assertFalse(any(r.get('type')=='shell-output' for r in self.rows()))
            out,err=proc.communicate(timeout=20)
        rows=self.rows();results=[r for r in rows if r.get('type')=='shell-output']
        self.assertEqual(len(results),1,err[-2000:]);self.assertTrue(results[0]['timed_out'])
        self.assertIn('absolute',results[0]['feedback']);self.assertLess(results[0]['exec_s'],15)
        self.assertNotEqual(results[0]['exit'],0)
    def test_large_reasoning_command_and_final_avoid_argument_limit(self):
        self.env['SHELLM_EXEC_TIMEOUT']='30'
        self.stub('R'*160000+'\n```bash\n#'+'C'*160000+'\nFINAL="$(python3 -c \'print("F"*160000)\')"\n```\n')
        run=subprocess.run([str(self.b/'shellm'),'-q','--workdir',str(self.wd),'large records'],env=self.env,stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=40)
        self.assertEqual(run.returncode,0,run.stderr[-2000:]);self.assertEqual(len(run.stdout.strip()),160000)
        rows=self.rows();self.assertGreater(len(next(r for r in rows if r.get('execution_started'))['thought']),150000)
        self.assertEqual(len(next(r for r in rows if r.get('type')=='final')['content']),160000)
    def test_fixture_resets_inherited_identity_and_report_paths(self):
        source=Path(__file__).resolve().parents[2]/'runtime/headlong/tests/isolated-env.sh'
        env={**self.env,'TRAJ_DIR':'/live','ROOT_TRAJ_ID':'live','SHELLM_RUN_ID_OUT':'/live/report','_SHELLM_PARENT_TRAJ_ID':'live'}
        r=subprocess.run(['bash','-c','source "$1"; env','fixture',str(source)],env=env,capture_output=True,text=True,check=True)
        for key in ['TRAJ_DIR','ROOT_TRAJ_ID','SHELLM_RUN_ID_OUT','_SHELLM_PARENT_TRAJ_ID']:self.assertNotIn(key+'=',r.stdout)
