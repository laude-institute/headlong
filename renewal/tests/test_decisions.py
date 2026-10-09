"""Decision transport, outage isolation, privacy and real shellm hook contracts.

Run under hermetic: all providers are fakes, no live model or transport is called.
"""
import copy
import io
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT/'runtime/headlong/bin'), str(ROOT/'renewal')]
import headlong_decision_contract as contract
import headlong_decisions as decisions
import custos_decision_broker as broker
import custos_decision_observer as observer
from test_delivery_honesty import ShellmStubFixture, executable


def request():
    return {'state': {'facts': 'The service is running.'}, 'questions': {
        'choice': {'type': 'choice', 'instructions': 'Service status?',
                   'criteria': {'up': 'Running', 'down': 'Stopped', 'insufficient': 'Unknown'}},
        'score': {'type': 'score', 'instructions': 'Evidence quality?', 'criteria': ['Absent', 'Direct']},
        'truth': {'type': 'noul', 'instructions': 'Is the service running?'}}}


def snap(payload, **kwargs):
    answers = {}
    for key, q in payload['questions'].items():
        if q['type'] == 'noul':
            answers[key] = {'type': 'noul', 'noul': .75}
        else:
            labels = list(q['criteria']) if q['type'] == 'choice' else list(map(str, range(len(q['criteria']))))
            answers[key] = {'type': q['type'], 'confidence': .7,
                            'probabilities': {k: (1 if k == labels[0] else 0) for k in labels}}
            answers[key]['choice' if q['type'] == 'choice' else 'score'] = labels[0] if q['type'] == 'choice' else 0
    return {'model': 'snap:2b', 'answers': answers, 'state_truncated': False}, 'snap1'


def jev(payload, **kwargs):
    value = snap(payload)[0]
    value.update(provider='typesafe', model='jev-latest')
    value.pop('state_truncated')
    return value


class ContractTests(unittest.TestCase):
    def test_mixed_primitives(self):
        payload = contract.validate_request(request())
        answers = contract.validate_answers(snap(payload)[0], payload)
        self.assertEqual(answers['choice']['choice'], 'up')
        self.assertEqual(answers['score']['legend'], {'0': 'Absent', '1': 'Direct'})
        self.assertEqual(answers['truth']['noul'], .75)

    def test_request_rejections(self):
        cases = []
        for k, v in [('endpoint', 'http://evil'), ('model', 'other'), ('state', None), ('keep_alive', 0)]:
            p = request(); p[k] = v; cases.append(p)
        p=request();p['questions']={};cases.append(p)
        p=request();p['questions']={str(i):p['questions']['truth'] for i in range(9)};cases.append(p)
        p=request();p['questions']['choice']['criteria']={str(i):'x' for i in range(27)};cases.append(p)
        p=request();p['questions']['score']['criteria']=['x']*11;cases.append(p)
        p=request();p['questions']['truth']['criteria']={'perhaps':'x'};cases.append(p)
        p=request();p['state']='x'*contract.MAX_REQUEST;cases.append(p)
        p=request();p['state']={'bad':float('nan')};cases.append(p)
        for value in cases:
            with self.subTest(value=str(value)[:80]), self.assertRaises((ValueError, TypeError)):
                contract.validate_request(value)

    def test_duplicate_and_nonfinite_json(self):
        for raw in ['{"a":1,"a":2}', '{"a":NaN}', '{"a":Infinity}']:
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                contract.decode(raw)

    def test_response_must_match_every_label_and_type(self):
        p=contract.validate_request(request())
        cases=[]
        for key,value in [('model','wrong'), ('state_truncated',True), ('state_truncated',None)]:
            r=snap(p)[0];r[key]=value;cases.append(r)
        r=snap(p)[0];r['answers'].pop('truth');cases.append(r)
        r=snap(p)[0];r['answers']['extra']={};cases.append(r)
        r=snap(p)[0];r['answers']['choice']['choice']='invented';cases.append(r)
        r=snap(p)[0];r['answers']['choice']['probabilities']['up']=.5;cases.append(r)
        r=snap(p)[0];r['answers']['truth']['noul']=True;cases.append(r)
        r=snap(p)[0];r['answers']['truth']['noul']=float('nan');cases.append(r)
        r=snap(p)[0];r['answers']['score']['score']=2;cases.append(r)
        for value in cases:
            with self.subTest(value=value), self.assertRaises(ValueError):
                contract.validate_answers(value,p)


class BrokerTests(unittest.TestCase):
    def setUp(self):
        self.primary=mock.Mock(side_effect=snap)
        self.fallback=mock.Mock(side_effect=jev)
        self.server=broker.Server(('127.0.0.1',0),self.primary,self.fallback)
        self.addCleanup(self.server.server_close)
        self.payload=contract.validate_request(request())

    def test_primary_success_never_calls_cloud(self):
        result=self.server.assess(self.payload,'shadow')
        self.assertEqual((result['provider'],result['model']),('tycho','snap:2b'))
        self.assertFalse(result['fallback']);self.fallback.assert_not_called()

    def test_connection_failure_uses_existing_jev_broker(self):
        self.primary.side_effect=OSError('offline')
        result=self.server.assess(self.payload,'shadow')
        self.assertEqual((result['provider'],result['model']),('typesafe','jev-latest'))
        self.assertTrue(result['fallback']);self.assertIsNone(result['artifact_sha256'])
        self.assertIsNone(result['state_truncated'])
        self.assertEqual(self.fallback.call_args.kwargs['timeout'],1)

    def test_truncated_primary_is_not_accepted(self):
        value=snap(self.payload)[0];value['state_truncated']=True
        self.primary.return_value=(value,'snap1');self.primary.side_effect=None
        self.assertEqual(self.server.assess(self.payload,'tool')['provider'],'typesafe')

    def test_invalid_input_never_spills_to_cloud(self):
        self.primary.side_effect=urllib.error.HTTPError('http://tycho',422,'bad',{},None)
        with self.assertRaisesRegex(ValueError,'upstream_rejected_input'):
            self.server.assess(self.payload,'shadow')
        self.fallback.assert_not_called()

    def test_circuit_skips_unavailable_primary_then_recovers(self):
        self.primary.side_effect=OSError('offline')
        for _ in range(4):self.server.assess(self.payload,'shadow')
        self.assertEqual(self.primary.call_count,3)
        self.server.open_until=0;self.primary.side_effect=snap
        self.assertEqual(self.server.assess(self.payload,'shadow')['provider'],'tycho')
        self.assertEqual(self.server.failures,0)

    def test_fallback_invalid_result_rejected(self):
        self.primary.side_effect=OSError('offline')
        self.fallback.side_effect=lambda *a,**k:{'provider':'typesafe','model':'wrong','answers':{}}
        with self.assertRaises(ValueError):self.server.assess(self.payload,'shadow')

    def test_both_providers_fail_without_retry(self):
        self.primary.side_effect=OSError('offline');self.fallback.side_effect=OSError('offline')
        with self.assertRaises(OSError):self.server.assess(self.payload,'shadow')
        self.assertEqual(self.primary.call_count,1);self.assertEqual(self.fallback.call_count,1)

    def start(self):
        thread=threading.Thread(target=self.server.serve_forever,daemon=True);thread.start()
        self.addCleanup(self.server.shutdown)
        return 'http://127.0.0.1:'+str(self.server.server_port)

    def test_http_protocol_and_metadata(self):
        base=self.start()
        req=urllib.request.Request(base+'/evaluate',data=contract.encode(request()).encode(),
                                   headers={'Content-Type':'application/json','X-Decision-Mode':'shadow'})
        with urllib.request.urlopen(req) as r:body=json.load(r)
        self.assertEqual(body['provider'],'tycho')
        with urllib.request.urlopen(base+'/health') as r:body=json.load(r)
        self.assertEqual(body['upstream_health'],'not_probed')
        self.assertEqual(body['fallback_model'],'jev-latest')

    def test_unauthorized_origin_and_unknown_route(self):
        base=self.start()
        for path,headers,status in [('/health',{'Origin':'https://foreign'},403),('/api/pull',{},404)]:
            with self.subTest(path=path),self.assertRaises(urllib.error.HTTPError) as caught:
                urllib.request.urlopen(urllib.request.Request(base+path,headers=headers))
            self.assertEqual(caught.exception.code,status)
        self.primary.assert_not_called();self.fallback.assert_not_called()

    def test_busy_and_rate_limit(self):
        base=self.start();self.server.slots.acquire();self.server.slots.acquire()
        req=urllib.request.Request(base+'/evaluate',data=contract.encode(request()).encode(),headers={'Content-Type':'application/json'})
        with self.assertRaises(urllib.error.HTTPError) as caught:urllib.request.urlopen(req)
        self.assertEqual(caught.exception.code,429)
        self.primary.assert_not_called();self.fallback.assert_not_called()
        self.server.slots.release();self.server.slots.release()
        self.server.calls.extend([time.monotonic()]*240)
        self.assertEqual(self.server.reserve(),'rate_limited')

    def test_two_calls_can_overlap(self):
        barrier=threading.Barrier(2)
        def transport(payload,**kwargs):barrier.wait(timeout=2);return snap(payload)
        self.server.transport=transport
        base=self.start();results=[]
        def call():
            req=urllib.request.Request(base+'/evaluate',data=contract.encode(request()).encode(),headers={'Content-Type':'application/json'})
            with urllib.request.urlopen(req,timeout=3) as r:results.append(json.load(r))
        threads=[threading.Thread(target=call) for _ in range(2)]
        for t in threads:t.start()
        for t in threads:t.join(4)
        self.assertEqual(len(results),2)
        self.assertTrue(all(r.get('provider')=='tycho' for r in results))


class ObserverTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.settings={'enabled':True,'mode':'shadow','shadow_hooks':['context','progress','response'],
                       'audit_dir':str(self.root/'audit'),'endpoint':'http://192.168.86.69:18085/evaluate'}
        self.payload={'request':'Check service status.', 'messages':[{'role':'user','content':'The status tool says running.'}],
                      'response':'The service is running.', 'skills':{'ops':'Service inspection','food':'Meal planning'}}

    def transport(self,payload,settings):
        value=snap(payload)[0]
        value.update(provider='tycho',artifact_sha256=contract.MODEL_SHA256)
        return value

    def test_all_hooks_preserve_input_and_never_apply(self):
        before=copy.deepcopy(self.payload)
        for hook in decisions.HOOKS:
            result=decisions.observe(hook,self.payload,self.settings,run_id='run1',transport=self.transport)
            self.assertEqual(result['status'],'assessed');self.assertFalse(result['applied'])
        self.assertEqual(self.payload,before)
        rows=[json.loads(s) for s in (self.root/'audit/assessments.jsonl').read_text().splitlines()]
        self.assertEqual(len(rows),3)
        self.assertTrue(all(r['rubric_sha256'] and r['evidence_sha256'] for r in rows))
        self.assertEqual((self.root/'audit/assessments.jsonl').stat().st_mode & 0o777,0o600)

    def test_disabled_makes_no_request_or_audit(self):
        transport=mock.Mock();self.settings['enabled']=False
        self.assertEqual(decisions.observe('response',self.payload,self.settings,transport=transport)['status'],'disabled')
        transport.assert_not_called();self.assertFalse((self.root/'audit').exists())

    def test_provider_failure_is_logged_not_raised(self):
        result=decisions.observe('response',self.payload,self.settings,transport=mock.Mock(side_effect=TimeoutError()))
        self.assertEqual(result['status'],'unavailable');self.assertEqual(result['error'],'deadline')
        self.assertFalse(result['applied'])

    def test_actual_fallback_provider_is_recorded(self):
        def fallback(payload,settings):return {**jev(payload), 'artifact_sha256':None}
        result=decisions.observe('response',self.payload,self.settings,transport=fallback)
        self.assertEqual(result['provider'],'typesafe');self.assertEqual(result['model'],'jev-latest')

    def test_large_context_is_explicitly_excerpted(self):
        self.payload['request']='x'*200000
        self.payload['messages']=[{'role':'user','content':'y'*10000} for _ in range(20)]
        p=decisions.packet('context',self.payload)
        self.assertLess(len(contract.encode(p).encode()),16000)
        self.assertTrue(p['state']['task']['excerpted'])
        self.assertEqual(p['state']['messages_omitted'],14)

    def test_secrets_redacted_before_packet_or_log(self):
        secret='sk-or-v1-'+'a'*50
        self.payload['request']='Read this '+secret+' and password=long-secret-value'
        r=decisions.observe('response',self.payload,self.settings,transport=self.transport)
        self.assertNotIn(secret,contract.encode(r));self.assertNotIn('long-secret-value',contract.encode(r))

    def test_image_limits_and_insufficient_option(self):
        self.payload['images_present']=True
        p=decisions.packet('response',self.payload)
        self.assertIn('insufficient',p['questions']['grounding']['criteria'])
        self.assertTrue(any('not visible' in x for x in p['state']['limits']))

    def test_total_deadline_includes_slow_peer(self):
        started=time.monotonic()
        with self.assertRaises(TimeoutError),decisions.deadline(.03):time.sleep(.3)
        self.assertLess(time.monotonic()-started,.2)

    def test_network_destination_is_fixed(self):
        self.settings['endpoint']='https://evil.example/evaluate'
        with self.assertRaisesRegex(ValueError,'unexpected_broker_endpoint'):
            decisions.evaluate(request(),self.settings)

    def test_audit_rotation_is_bounded(self):
        root=self.root/'audit';root.mkdir()
        (root/'assessments.jsonl').write_bytes(b'x'*(8*1024*1024))
        for i in (1,2,3):(root/('assessments.%d.jsonl'%i)).write_text('old'+str(i))
        decisions.audit({'status':'new'},self.settings)
        self.assertEqual(json.loads((root/'assessments.jsonl').read_text())['status'],'new')
        self.assertEqual((root/'assessments.3.jsonl').read_text(),'old2')

    def test_responder_error_does_not_change_plan(self):
        plan={'decision':'reply','reply':'Hello','goal':None};before=copy.deepcopy(plan)
        with mock.patch.dict(os.environ,{'HEADLONG_ROOT':str(ROOT/'runtime/headlong')}),mock.patch.object(
                observer.subprocess,'run',side_effect=observer.subprocess.TimeoutExpired('decide',3)):
            observer.observe_response({'content':'Hi'},[],plan,'trigger')
        self.assertEqual(plan,before)


class ShellmDecisionTests(ShellmStubFixture):
    def test_hooks_cannot_change_output_or_inject_context_even_when_client_fails(self):
        cfg=self.work/'decisions.json';cfg.write_text('{}')
        self.env['HEADLONG_DECISIONS_CONFIG']=str(cfg)
        calls=self.work/'calls.jsonl'
        executable(self.toolbin/'decide', '#!/usr/bin/env python3\nimport json,sys\nfrom pathlib import Path\n'
                   'p=json.loads(Path(sys.argv[1]).read_text())\n'
                   'with open('+repr(str(calls))+',"a") as f:f.write(json.dumps({"argv":sys.argv,"packet":p})+"\\n")\n'
                   'print("SNAP_SENTINEL_DO_NOT_OBEY");sys.exit(1)\n')
        for n in range(1,5):self.fence(str(n),'echo evidence-'+str(n))
        self.fence('last','FINAL=original-answer')
        result=self.run_shellm('--max-iterations','5','Inspect the fixture')
        self.assertEqual(result.returncode,0,result.stderr[-2000:])
        self.assertIn('original-answer',result.stdout)
        rows=[json.loads(s) for s in calls.read_text().splitlines()]
        self.assertEqual([r['argv'][r['argv'].index('--observe')+1] for r in rows],['context','progress','response'])
        self.assertEqual(rows[-1]['packet']['response'],'original-answer')
        self.assertIn('evidence-4',rows[1]['packet']['last_step']['stdout'])
        self.assertNotIn('SNAP_SENTINEL',json.dumps(self.steps(),default=str))


if __name__=='__main__':unittest.main()
