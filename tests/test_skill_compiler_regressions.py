"""Offline black-box regressions, invoked by test_skill_compiler.sh.

All skills, model responses, trajectories, credentials and workdirs are synthetic.
The same checks can be pointed at a copy of the pre-fix compiler.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

SC = Path(sys.argv[1]).resolve()
ROOT = Path(sys.argv[2]).resolve()
ROOT.mkdir(parents=True, exist_ok=True)
STUBS = ROOT / 'stubs'
STUBS.mkdir()
PYTHON = sys.executable
REAL_JQ = shutil.which('jq')

STUB = r'''import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
root = pathlib.Path(os.environ['CASE_ROOT'])
argv_max = max([0] + [len(x.encode()) for x in sys.argv[1:]])
env_max = max(len((k+'='+v).encode()) for k,v in os.environ.items())
with (root/'exec-sizes.jsonl').open('a') as f:
    f.write(json.dumps(dict(tool=name, argv=argv_max, env=env_max))+'\n')
if os.environ.get('LIMIT_PROBE') == '1' and max(argv_max,env_max) >= 131072:
    print('Linux-sized exec string limit exceeded',file=sys.stderr)
    sys.exit(90)
if name == 'jq':
    os.execv(os.environ['REAL_JQ'], ['jq']+sys.argv[1:])
if name == 'python3':
    os.execv(os.environ['REAL_PYTHON'], ['python3']+sys.argv[1:])
if name == 'mkdir':
    if os.environ.get('BREAK_NEXT_SETUP') == '1' and sys.argv[-1].endswith('/traj'):
        counter=root/'setup-count'
        n=int(counter.read_text())+1 if counter.exists() else 1
        counter.write_text(str(n))
        if n==2: sys.exit(1)
    os.execv('/bin/mkdir', ['mkdir']+sys.argv[1:])
if name == 'skills':
    sys.exit(0)
if name == 'sleep':
    with (root/'sleeps').open('a') as f: f.write(sys.argv[1]+'\n')
    sys.exit(0)
if name == 'llm':
    counter=root/'teacher-count'
    n=int(counter.read_text())+1 if counter.exists() else 1
    counter.write_text(str(n))
    (root/'teacher-args.json').write_text(json.dumps(sys.argv[1:]))
    prompt = sys.stdin.read()
    if not prompt and len(sys.argv)>1: prompt=sys.argv[-1]
    (root/'teacher-prompt').write_text(prompt)
    if n <= int(os.environ.get('TEACHER_FAILURES','0')):
        print('synthetic teacher failure',file=sys.stderr)
        sys.exit(1)
    if os.environ.get('TEACHER_EMPTY') == '1': sys.exit(0)
    print((root/'tests.json').read_text())
    sys.exit(0)
if name == 'shellm':
    args=sys.argv[1:]
    if '--prompt-file' in args:
        prompt=pathlib.Path(args[args.index('--prompt-file')+1]).read_text()
    else: prompt=args[-1]
    (root/'shell-prompt').write_text(prompt)
    traj=pathlib.Path(os.environ['TRAJ_DIR']);traj.mkdir(parents=True,exist_ok=True)
    if os.environ.get('NO_TRAJECTORY') != '1':
        run_id='new-root-run'
        header=[dict(type='trajectory',step_id='new-root-trajectory'),
                dict(type='shellm-run',step_id=run_id)]
        rows=[json.loads(line) for line in (root/'trajectory.jsonl').read_text().splitlines()]
        rows=[dict(r,run_id=r.get('run_id',run_id)) for r in rows]
        parent=traj/'root';parent.mkdir()
        (parent/'trajectory.jsonl').write_text(''.join(json.dumps(r,separators=(',',':'))+'\n' for r in header+rows))
        if os.environ.get('SHELLM_RUN_ID_OUT') and os.environ.get('NO_RUN_HANDSHAKE') != '1':
            pathlib.Path(os.environ['SHELLM_RUN_ID_OUT']).write_text(run_id)
        if os.environ.get('NESTED_TRAJECTORY') == '1':
            child=parent/'child';child.mkdir()
            child_rows=[dict(type='trajectory',step_id='child',parent_traj='new-root-trajectory'),
                        dict(type='shellm-run',step_id='child-run'),
                        dict(type='final',content='Child-only success',run_id='child-run')]
            (child/'trajectory.jsonl').write_text(''.join(json.dumps(r,separators=(',',':'))+'\n' for r in child_rows))
        if os.environ.get('AMBIGUOUS_ROOT') == '1':
            (traj/'duplicate.jsonl').write_text((parent/'trajectory.jsonl').read_text())
    if (root/'fixture.txt').exists():
        (pathlib.Path(os.environ['SHELLM_RUNDIR'])/'input.txt').write_text((root/'fixture.txt').read_text())
    print('synthetic runner diagnostic',file=sys.stderr)
    sys.exit(int(os.environ.get('RUNNER_RC','0')))
'''
for name in ('llm', 'shellm', 'skills', 'jq', 'python3', 'mkdir', 'sleep'):
    p = STUBS / name
    p.write_text('#!' + PYTHON + '\n' + STUB)
    p.chmod(0o755)

count = 0
failed = 0


def check(name, fn):
    global count, failed
    if os.environ.get('REGRESSION_FILTER') and os.environ['REGRESSION_FILTER'] not in name:
        return
    count += 1
    try:
        fn()
        print('ok   regression: ' + name, flush=True)
    except Exception as exc:
        failed += 1
        print('FAIL regression: ' + name + ': ' + str(exc)[:500], flush=True)


class Case:
    def __init__(self, name):
        self.root = ROOT / name
        self.root.mkdir()
        self.skills = self.root / 'skills & #'
        self.skills.mkdir()
        self.cache = self.root / 'compiled'
        self.env = dict(os.environ)
        for key in list(self.env):
            if key.startswith(('SKILL_', 'SC_', 'SHELLM_', 'HEADLONG_', 'LLM_', 'TRAJ_', 'MEM_', 'ROOT_TRAJ_')) or key.endswith(('_API_KEY', '_TOKEN')):
                self.env.pop(key)
        self.env.update(HOME=str(self.root/'home'), HEADLONG_HOME=str(self.root/'state'),
                        SKILLS_DIR=str(self.skills), SKILLS_KERNEL_DIR=str(self.root/'kernel'),
                        SKILL_COMPILED_DIR=str(self.cache), SC_TMP_BASE=str(self.root/'tmp'),
                        SC_RUNS_BASE=str(self.root/'runs'), SHELLM_ENV='local', SKILL_AUTO_HARVEST='0',
                        PATH=str(STUBS)+os.pathsep+os.environ['PATH'], CASE_ROOT=str(self.root),
                        REAL_JQ=REAL_JQ, REAL_PYTHON=PYTHON)
        (self.root/'home').mkdir()
        self.skill('probe', 'Run python3 probe.py.\n', 'print("Victory phrase stable")\n')
        self.tests([dict(name='probe-test', prompt='Run the probe.', expect='final',
                         expect_contains=['Victory phrase stable'])])
        self.output('Victory phrase stable')

    def skill(self, name, body='', script=None):
        d=self.skills/name; d.mkdir(exist_ok=True)
        (d/'SKILL.md').write_text('---\nname: '+name+'\ndescription: Fixture.\n---\n'+body)
        if script is not None: (d/(name+'.py')).write_text(script)
        return d

    def tests(self, tests):
        (self.root/'tests.json').write_text(json.dumps(tests))

    def output(self, text, final='Reported.'):
        records=[dict(type='shell-output', stdout=text), dict(type='final',content=final)]
        (self.root/'trajectory.jsonl').write_text(''.join(json.dumps(r,separators=(',',':'))+'\n' for r in records))

    def run(self, command='compile', skill='probe', extra=(), success=True):
        r=subprocess.run([os.environ.get('SC_TEST_BASH', '/bin/bash' if sys.platform=='darwin' else 'bash'), str(SC), command, '--skill',skill,*extra],
                         env=self.env,cwd=self.root,text=True,capture_output=True,timeout=90)
        with (self.root/'commands.log').open('a') as f:
            f.write(f'{command} {skill}: rc={r.returncode}\n'+r.stdout+r.stderr)
        if success: assert r.returncode==0, (r.stderr+r.stdout)[-600:]
        return r

    def result(self):
        return json.loads((self.cache/'probe.json').read_text())


def fixture_only():
    c=Case('fixture-only'); c.output('', 'No work happened.')
    (c.root/'fixture.txt').write_text('prefix Victory phrase stable suffix\n')
    c.run(); assert c.result()['tests'][0]['pass'] is False
check('fixture text is not executed evidence',fixture_only)


def interleaved():
    c=Case('interleaved'); td=c.root/'trajectories';td.mkdir()
    records=[dict(type='reasoning',run_id='a',cmd='python3 probe.py'),
             dict(type='reasoning',run_id='b',cmd='echo unrelated'),
             dict(type='shell-output',run_id='a',stdout='Correct probe verdict'),
             dict(type='shell-output',run_id='b',stdout='Unrelated other verdict'),
             dict(type='reasoning',run_id='c',cmd='python3 probe.py'),
             dict(type='shell-output',run_id='d',stdout='Incorrectly attributed verdict'),
             dict(type='shell-output',run_id='c',stdout='Correct second verdict')]
    (td/'events.jsonl').write_text(''.join(json.dumps(x)+'\n' for x in records))
    c.env.update(SKILL_AUTO_HARVEST='1',SKILL_HARVEST_TRAJ_DIR=str(td),SKILL_HARVEST_MIN_COUNT='1')
    pool=json.loads(c.run('pool').stdout)
    assert 'Correct probe verdict' in pool and 'Correct second verdict' in pool
    assert 'Incorrectly attributed verdict' not in pool and 'Unrelated other verdict' not in pool
check('history follows run_id',interleaved)


def live(kind):
    c=Case('live-'+kind);d=c.skills/'probe'
    (d/'probe.py').unlink()
    (d/'SKILL.md').write_text('---\nname: probe\n---\nRun probe.'+kind+'\n')
    (d/('probe.'+kind)).write_text('print("".join(["runtime", " computed", " phrase"]))\n' if kind=='py'
                                  else 'printf "%s %s %s\\n" runtime computed phrase\n')
    # Relative configured roots must also become absolute before cd.
    c.env['SKILLS_DIR']=os.path.relpath(c.skills,c.root)
    assert 'runtime computed phrase' in json.loads(c.run('pool').stdout)
check('Python live-only vocabulary',lambda:live('py'))
check('shell live-only vocabulary',lambda:live('sh'))


def provenance():
    c=Case('provenance');h=c.root/'history.json'
    h.write_text(json.dumps(dict(script='probe.py',entries=[dict(line='Victory phrase stable',count=2)])))
    c.env['SKILL_HISTORY_POOL']=str(h)
    c.tests([dict(name='metadata',prompt='Run the probe.',expect='final',expect_contains=['probe.py','Victory phrase stable'])])
    c.output('probe.py Victory phrase stable');c.run()
    labels=c.result()['tests'][0]['literal_sources']
    assert labels['probe.py']!='TOOL-OUTPUT' and labels['Victory phrase stable']=='TOOL-OUTPUT'
check('history metadata is not captured output',provenance)


def empty_capture():
    c=Case('empty-capture');f=c.root/'empty.txt';f.write_text('')
    c.env['SKILL_REAL_OUTPUT']=str(f);c.run()
    assert c.result()['tests'][0]['literal_sources']['Victory phrase stable']=='SCRIPT-PRINT-UNATTESTED'
check('an empty capture is still occurrence evidence of absence',empty_capture)


def cap(kind):
    c=Case('cap-'+kind); target='zeta dropped real phrase'
    c.env.update(SKILL_POOL_CAP='1000', SKILL_POOL_SRC_CAP='1000',SKILL_POOL_LIVE_CAP='1000')
    if kind=='source':
        (c.skills/'probe'/'probe.py').write_text('import sys\nif len(sys.argv)==1: sys.exit(0)\n# print("alpha first phrase")\n# print("zeta dropped real phrase")\n')
        c.env['SKILL_POOL_SRC_CAP']='1'
    elif kind=='doc':
        c.skill('probe','`alpha first phrase`\n`zeta dropped real phrase`\n')
        (c.skills/'probe'/'probe.py').unlink();c.env['SKILL_POOL_SRC_CAP']='1'
    elif kind=='live':
        (c.skills/'probe'/'probe.py').write_text('print("alpha first phrase")\nprint(" ".join(["zeta", "dropped", "real", "phrase"]))\n')
        c.env['SKILL_POOL_LIVE_CAP']='1'
    else:
        h=c.root/'history.json';h.write_text(json.dumps(['alpha first phrase',target]))
        c.env.update(SKILL_HISTORY_POOL=str(h), SKILL_HARVEST_MAX_ENTRIES='1')
    c.tests([dict(name='cap',prompt='Run the probe.',expect='final',expect_contains=[target])])
    c.output(target);c.run();r=c.result()
    assert r['summary']['pool_truncated'] is True
    assert r['tests'][0]['literal_labels'][target]=='POOL-DROPPED'
    assert r['tests'][0]['verification']=='GREEN-ON-DROPPED'
for kind in ('source','doc','live','history'):check(kind+' cap retains dropped vocabulary',lambda k=kind:cap(k))


def refused():
    c=Case('refused');d=c.skill('slack','Run slack.py.\n','print("never execute")\n')
    (c.skills/'alias').symlink_to(d,target_is_directory=True)
    escaped=c.skill('escape');(escaped/'SKILL.md').unlink();(escaped/'SKILL.md').symlink_to(d/'SKILL.md')
    c.skill('declared');(c.skills/'declared'/'SKILL.md').write_text('---\nname: slack\n---\n')
    accepted=[]
    for name in ('slack','slack/','./slack','../skills & #/slack','alias','escape','declared'):
        for cmd in ('compile','pool'):
            marker=c.root/'teacher-args.json'
            if marker.exists(): marker.unlink()
            r=c.run(cmd,name,success=False)
            if r.returncode==0 or marker.exists(): accepted.append(f'{cmd} {name}')
    # A normal installer-style link retains its basename and is supported.
    d=c.root/'installed'/'safe';d.mkdir(parents=True);(d/'SKILL.md').write_text('---\nname: safe\n---\n')
    (c.skills/'safe').symlink_to(d,target_is_directory=True);c.run('pool','safe')
    assert not accepted, 'accepted: '+', '.join(accepted)
check('refusal spellings, aliases, escaped spec, and installed symlink',refused)


def rewriting():
    c=Case('paths');absolute=str(c.skills/'probe'/'probe.py')
    c.tests([dict(name='paths',prompt='Run skills/probe/probe.py and '+absolute,expect='final',expect_contains=[])])
    c.run();p=(c.root/'shell-prompt').read_text()
    assert 'Run '+absolute+' and '+absolute in p
check('stock macOS path rewriting preserves absolute paths and special characters',rewriting)


def parser_provider():
    c=Case('parser');spec=c.skills/'probe'/'SKILL.md'
    spec.write_text('---\nname: probe\ndescription: secret metadata marker\nmetadata:\n  shelllm:\n    requires:\n      bins: [bash, definitely-absent]\n---\nBody.\n---\n## Usage\nlast usage line\n')
    c.env.update(SHELLM_MODEL='configured-model',LLM_PROVIDER='adapter')
    c.run(extra=('--teacher-model','explicit-model'))
    args=json.loads((c.root/'teacher-args.json').read_text())
    assert '--provider' not in args and args==['-m','explicit-model']
    text=(c.root/'teacher-prompt').read_text()
    obj,_=json.JSONDecoder().raw_decode(text.split('SKILL SPECIFICATION (JSON):\n')[1])
    assert obj['body']=='Body.\n---\n## Usage\nlast usage line\n'
    assert obj['usage_section'].endswith('last usage line\n')
    assert 'definitely-absent: NOT INSTALLED' in text
    c.run();assert json.loads((c.root/'teacher-args.json').read_text())==[]
    (c.root/'shell-prompt').unlink();c.tests([dict(name='invalid',prompt='Run.',expect='thought')])
    assert c.run(success=False).returncode!=0 and not (c.root/'shell-prompt').exists()
check('frontmatter, terminal Usage, declared binaries and provider delegation',parser_provider)


def negatives():
    c=Case('negative-matcher')
    rows=[('missing',['missing phrase'],'Victory phrase stable',False),
          ('denial',['violation'],'No violations found',False),
          ('clean-but-asserts-violation',['violation'],'No violations found',False),
          ('digit',['5 tests passed'],'15 tests passed',False),
          ('and',['Victory phrase stable','missing phrase'],'Victory phrase stable',False),
          ('clean',['No violations found'],'No violations found',True),
          ('digit-ok',['5 tests passed'],'5 tests passed',True),
          ('positive',['Victory phrase stable'],'Victory phrase stable',True)]
    for name,literals,out,want in rows:
        c.tests([dict(name=name,prompt='Run the probe.',expect='final',expect_contains=literals)])
        c.output(out);c.run();assert c.result()['tests'][0]['pass']==want,name
    # Exact prompt echoes must not become evidence, including the final answer.
    c.tests([dict(name='echo',prompt='Victory phrase stable',expect='final',expect_contains=['Victory phrase stable'])])
    c.output('Victory phrase stable','Victory phrase stable');c.run()
    assert c.result()['tests'][0]['pass'] is False
    fixture=json.dumps(dict(message='Victory phrase stable'))
    (c.root/'fixture.txt').write_text(fixture+'\n')
    c.tests([dict(name='fixture-echo',prompt='Run the probe.',expect='final',expect_contains=['Victory phrase stable'])])
    c.output(fixture,fixture);c.run();assert c.result()['tests'][0]['pass'] is False
    (c.root/'fixture.txt').unlink()
    c.tests([dict(name='empty',prompt='Run.',expect='final',expect_contains=[])])
    c.output('','');c.run();assert c.result()['tests'][0]['pass'] is False
    c.output('','Answered.');c.run();assert c.result()['tests'][0]['verification']=='GREEN-NO-LITERALS'
check('missing, denial, digit boundaries, AND, echoes and empty final/literals',negatives)


def large():
    c=Case('large');c.env['LIMIT_PROBE']='1'
    big='long evidence '*11000
    c.skill('probe', 'Large body '+big+'\n')
    c.tests([dict(name='large',prompt='Run the probe. '+big,expect='final',expect_contains=[big.strip()])]*2)
    c.output(big,big);c.run();r=c.result()
    assert len(r['tests'])==2 and all(x['pass'] for x in r['tests']), [(x.get('pass'), x.get('last_step_type'), x.get('expect_contains_matched'), x.get('harness_error')) for x in r['tests']]
    sizes=[json.loads(x) for x in (c.root/'exec-sizes.jsonl').read_text().splitlines()]
    assert max(max(x['argv'],x['env']) for x in sizes)<131072
    assert (c.cache/'probe.json').stat().st_size>131072
check('large skill, prompts, literals, answers and aggregate results avoid exec limits',large)


def lifecycle():
    c=Case('lifecycle');r=c.run()
    assert 'Running test 1/1: probe-test' in r.stdout and 'Test result: true' in r.stdout
    assert not list((c.root/'tmp').glob('run.*'))
    assert not list((c.root/'runs').glob('*'))
    c.run('clean'); assert not [p for p in c.cache.iterdir() if 'probe' in p.name]
    c.env.pop('SKILL_COMPILED_DIR');c.run()
    assert (c.root/'state'/'skill-compiler'/'compiled'/'probe.json').exists()
check('progress, temporary cleanup, complete clean and persistent state cache',lifecycle)


def partial():
    c=Case('partial');c.env['BREAK_NEXT_SETUP']='1'
    t=json.loads((c.root/'tests.json').read_text())[0];c.tests([t,dict(t,name='second')])
    r=c.run(success=False);assert r.returncode!=0
    results=c.result()['tests'];assert results[0]['pass'] and not results[1]['pass']
    assert 'harness_error' in results[1]
check('setup failure retains preceding results and records a failed test',partial)


def history_defaults():
    c=Case('history-defaults');td=c.root/'state'/'trajectories';td.mkdir(parents=True)
    rows=[dict(type='reasoning',cmd='python3 probe.py'),dict(type='shell-output',stdout='Notes: A1 B2 C3\nVerdict line from history')]*2
    f=td/'test.jsonl';f.write_text(''.join(json.dumps(x)+'\n' for x in rows))
    c.env['SKILL_AUTO_HARVEST']='1';pool=json.loads(c.run('pool').stdout)
    assert 'Notes: A1 B2 C3' in pool  # music filter is not generic output policy
    h=c.root/'state'/'skill-compiler'/'history'/'pool-history-probe.json';before=h.stat().st_mtime_ns
    c.run('pool');assert h.stat().st_mtime_ns==before
    # Explicit music opt-in must invalidate the generic cached view.
    c.env['SKILL_HARVEST_ECHO_FILTER']='music';pool=json.loads(c.run('pool').stdout)
    assert 'Notes: A1 B2 C3' not in pool and 'Verdict line from history' in pool
    c.env.pop('HEADLONG_HOME');c.env.pop('SKILL_HARVEST_ECHO_FILTER')
    legacy=c.root/'home'/'.shellm';shutil.copytree(c.root/'state',legacy)
    pool=json.loads(c.run('pool').stdout);assert 'Verdict line from history' in pool
check('state-home history, reusable TTL and opt-in music filter',history_defaults)



def teacher_bytes():
    c=Case('teacher-bytes')
    body=r'cd x && y; literal \path\ and __SKILL_ABS__ __NUM_TESTS__ __BINS_STATUS__'
    phrase=r'alpha & beta \slash __SKILL_SPEC__ __SKILL_ABS__'
    c.skill('probe',body+'\n','print('+repr(phrase)+')\n')
    c.run(); text=(c.root/'teacher-prompt').read_text()
    spec,_=json.JSONDecoder().raw_decode(text.split('SKILL SPECIFICATION (JSON):\n')[1])
    pool,_=json.JSONDecoder().raw_decode(text.split('PHRASE POOL (verbatim vocabulary, not a claim of behavioral coverage):\n')[1])
    offered=json.loads((c.cache/'pool-probe.json').read_text())['offered']
    assert spec['body']==body+'\n',spec['body']
    assert pool==offered and phrase in pool
    assert str(c.skills/'probe')+'/<file>' in text
check('verbatim teacher interpolation, ampersands, backslashes and placeholder data',teacher_bytes)


def ranking():
    c=Case('ranking');c.skill('probe','Example `aaa documentation phrase`.\n','print("zzz live script phrase")\n')
    c.env['SKILL_POOL_CAP']='1'
    assert json.loads(c.run('pool').stdout)==['zzz live script phrase']
check('script and live source priority survives combined cap',ranking)


def history_ranking():
    c=Case('history-ranking')
    h=c.root/'history.json'
    h.write_text(json.dumps(dict(entries=[dict(line='aaa rare output',count=2),dict(line='zzz frequent output',count=100),dict(line='zzz frequent output',count=100)])))
    c.env.update(SKILL_HISTORY_POOL=str(h),SKILL_HARVEST_MAX_ENTRIES='1',SKILL_POOL_CAP='100')
    pool=json.loads(c.run('pool').stdout)
    assert 'zzz frequent output' in pool and 'aaa rare output' not in pool
    dropped=json.loads((c.cache/'pool-probe.json').read_text())['dropped']
    assert 'aaa rare output' in dropped
check('history frequency survives source cap and deduplication',history_ranking)


def outcome(expect):
    c=Case('outcome-'+expect)
    c.tests([dict(name='outcome',prompt='Run the probe.',expect=expect,expect_contains=[])])
    def run(rows,rc,want,harness=False):
        (c.root/'trajectory.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
        c.env['RUNNER_RC']=str(rc)
        r=c.run(success=False);test=c.result()['tests'][0]
        assert test['pass'] is want,(expect,rows,rc,test)
        assert ('harness_error' in test) is harness
        assert (r.returncode!=0) is harness
        assert test['runner_stderr']=='synthetic runner diagnostic\n'.rstrip('\n')
    named=dict(type=expect,content='Actual evidence')
    if expect=='shell-output': named=dict(type=expect,stdout='Actual evidence',**{'exit':0})
    if expect=='error': named=dict(type='shell-output',stderr='Actual skill failure',**{'exit':2})
    # First assert the reported false-positive path on the original compiler.
    run([] if expect=='error' else [named],1,False,True)
    # Each outcome also has a valid case without requiring an unrelated final.
    run([named],0,True)
    run([dict(type='reasoning',content='Still planning')],0,False)
    if expect in ('observation','shell-output'):
        run([dict(type='final',content='Wrong evidence kind')],0,False)
    run([],1,False,True)
    run([named],1,False,True)
    if expect=='error':
        run([dict(type='error',content='Provider failed',reason='stall')],0,False)
        run([dict(type='shell-output',stderr='No failure',**{'exit':0})],0,False)
        run([dict(type='shell-output',stderr='Timed out',timed_out=True,**{'exit':124})],0,False)
    else:
        run([dict(type=expect,content=' ',stdout='')],0,False)
    literal='Actual skill failure' if expect=='error' else 'Actual evidence'
    c.tests([dict(name='named-literal',prompt='Run the probe.',expect=expect,expect_contains=[literal])])
    run([named],0,True)
    # Literals cannot rescue an unsuccessful runner, including a final answer.
    c.tests([dict(name='attested-failure',prompt='Run the probe.',expect=expect,expect_contains=['Victory phrase stable'])])
    run([dict(named,content='Victory phrase stable',stdout='Victory phrase stable')],1,False,True)
    assert c.result()['tests'][0]['verification']=='FAIL'
for expected in ('final','observation','shell-output','error'):
    check('runner success and named evidence for '+expected,lambda e=expected:outcome(e))


def root_selection():
    c=Case('root-selection');c.env['NESTED_TRAJECTORY']='1'
    c.tests([dict(name='root',prompt='Run the probe.',expect='final',expect_contains=[])])
    def rows(values): (c.root/'trajectory.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in values))
    # Root is unfinished, child and a different run in the root file have finals.
    rows([dict(type='reasoning',content='Planning'),dict(type='final',content='Other run',run_id='other-run')])
    c.run();t=c.result()['tests'][0];assert not t['pass'] and t['final']==''
    c.env['RUNNER_RC']='1';c.run(success=False);assert not c.result()['tests'][0]['pass']
    c.env['RUNNER_RC']='0';rows([dict(type='final',content='Root success')]);c.run()
    assert c.result()['tests'][0]['final']=='Root success'
    c.tests([dict(name='child-literal',prompt='Run the probe.',expect='final',expect_contains=['Child-only success'])])
    c.run();assert not c.result()['tests'][0]['pass']
    for key in ('NO_RUN_HANDSHAKE','AMBIGUOUS_ROOT','NO_TRAJECTORY'):
        c.env[key]='1';r=c.run(success=False);t=c.result()['tests'][0]
        assert r.returncode!=0 and not t['pass'] and 'harness_error' in t,key
        del c.env[key]
check('actual root handshake excludes nested and unrelated run evidence',root_selection)


def probe_isolation(kind):
    c=Case('probe-isolation-'+kind);live=c.root/'pretend-live';live.mkdir()
    paths=('MEM_DIR','TRAJ_DIR','SHELLM_TRAJ_DIR','HEADLONG_HOME','SHELLM_HOME','SHELLM_CONF_DIR','SHELLM_ENVS_DIR')
    for k in paths:
        d=live/k;d.mkdir();(d/'sentinel').write_text('unchanged');c.env[k]=str(d)
    c.env.update(IDENTITY_DIR=str(live),IDENTITY_NAME='synthetic-live',TRAJ_ID='caller',ROOT_TRAJ_ID='caller',
                 _SHELLM_PARENT_TRAJ_ID='caller',SHELLM_RUN_ID_OUT=str(live/'caller-handshake'))
    (c.skills/'probe'/'probe.py').write_text(
        'import os,pathlib\n'
        'for k in '+repr(paths)+':\n p=pathlib.Path(os.environ[k]);(p/"probe-wrote").write_text("synthetic")\n'
        'assert not any(os.environ.get(k) for k in ("IDENTITY_DIR","IDENTITY_NAME","TRAJ_ID","ROOT_TRAJ_ID","_SHELLM_PARENT_TRAJ_ID","SHELLM_RUN_ID_OUT"))\n'
        'print("".join(["Isolated", " probe executed"]))\n')
    if kind=='sh':
        (c.skills/'probe'/'SKILL.md').write_text('---\nname: probe\n---\nRun probe.sh\n')
        (c.skills/'probe'/'probe.sh').write_text('exec python3 "$(dirname "$0")/probe.py" "$@"\n')
    for cmd in ('pool','compile'):
        r=c.run(cmd)
        offered=json.loads(r.stdout) if cmd=='pool' else json.loads((c.cache/'pool-probe.json').read_text())['offered']
        assert 'Isolated probe executed' in offered
        assert sorted(str(p.relative_to(live)) for p in live.rglob('*') if p.is_file())==sorted(k+'/sentinel' for k in paths)
for kind in ('py','sh'):
    check(kind+' pool and compile probes isolate identity-selected state',lambda k=kind:probe_isolation(k))


def matching_and_missed():
    c=Case('matching-and-missed')
    c.tests([dict(name='case',prompt='Run the probe.',expect='final',expect_contains=['Hello','Hello world'])])
    c.output('hello world');c.run();assert c.result()['tests'][0]['pass']
check('word and phrase case matching are consistent',matching_and_missed)


def missing_json():
    c=Case('missing-json')
    missed=['a | b', 'quote " and \\ slash', 'line one\nline two']
    c.tests([dict(name='missing',prompt='Run the probe.',expect='final',expect_contains=missed)])
    c.run();assert c.result()['tests'][0]['expect_contains_missed']==missed
check('missing-literal JSON preserves pipes, quotes, backslashes and newlines',missing_json)


def cap_validation():
    c=Case('cap-validation')
    for name in ('SKILL_POOL_CAP','SKILL_POOL_SRC_CAP','SKILL_POOL_LIVE_CAP','SKILL_HARVEST_MAX_ENTRIES'):
        for value in ('abc','-1','2.5',''):
            c.env[name]=value;r=c.run('pool',success=False)
            assert r.returncode!=0 and name in r.stderr and 'nonnegative integer' in r.stderr,(name,value,r.stderr)
        for value in ('0','200 ',' 02 '):
            c.env[name]=value;c.run('pool')
        del c.env[name]
check('caps validate domain and name bad settings, accepting surrounding whitespace',cap_validation)


def teacher_failures():
    for mode in ('failure','empty','recover'):
        c=Case('teacher-'+mode)
        if mode=='empty': c.env['TEACHER_EMPTY']='1'
        else: c.env['TEACHER_FAILURES']='2' if mode=='recover' else '4'
        r=c.run(success=False)
        assert (r.returncode==0)==(mode=='recover'),r.stderr
        assert (c.root/'sleeps').read_text().splitlines()==(['5','10'] if mode=='recover' else ['5','10','15'])
        if mode!='recover': assert 'llm configured default' in r.stderr and not (c.root/'shell-prompt').exists()
    c=Case('teacher-invalid-json');(c.root/'tests.json').write_text('invalid')
    assert c.run(success=False).returncode!=0 and not (c.root/'shell-prompt').exists()
check('teacher retry recovery, final delay, empty/invalid responses and default diagnostic',teacher_failures)


def direct_cache():
    global SC
    original=SC;copy=ROOT/'direct-compiler';copy.mkdir()
    shutil.copyfile(SC,copy/'skill-compiler');cache=copy/'.compiled';cache.mkdir()
    sentinel=cache/'sentinel';sentinel.write_text('retain')
    try:
        SC=copy/'skill-compiler';c=Case('direct-cache');c.run()
        assert sentinel.read_text()=='retain' and c.cache.parent==c.root
    finally: SC=original
check('direct helper leaves sibling cache untouched',direct_cache)


# Third repair: actual configuration loaders, stopped before any provider call.
def operator_config():
    import shlex
    repo = Path(__file__).resolve().parents[1]
    originals = {name: (STUBS/name).read_text() for name in ('llm','shellm')}
    keys = ['OPENROUTER_API_KEY','OPENAI_API_KEY','SHELLM_MODEL','SHELLM_API_URL',
            'LLM_API_URL','LLM_API_KEY','LLM_PROVIDER','LLM_ADAPTER','LLM_OR_ONLY',
            'LLM_OR_ZDR','LLM_RETRIES','SHELLM_EFFORT']
    capture = ('import os,json; print(json.dumps({k:os.environ.get(k) for k in '
               + repr(keys+['TRAJ_DIR','LLM_USAGE_LEDGER']) + '}))')
    prefixes = {}
    for name, marker in [('llm','\nLLM_MODEL='), ('shellm','\nSHELLM_MAX_TOKENS=')]:
        source = (repo/'bin'/name).read_text()
        assert marker in source
        prefixes[name] = source[:source.index(marker)]
    impl = ROOT/'loader-impl'; impl.mkdir()
    try:
        for name in originals:
            (impl/name).write_text(originals[name])
            wrapper = ('#!/bin/bash\n'+shlex.quote(PYTHON)+' -c '+shlex.quote(capture)
                       + ' > "$CASE_ROOT/'+name+'-before-config.json"\n'
                       + prefixes[name] + '\nexport SHELLM_MODEL SHELLM_API_URL\n'
                       + shlex.quote(PYTHON) + ' -c ' + shlex.quote(capture)
                       + ' > "$CASE_ROOT/'+name+'-config.json"\n'
                       + 'exec '+shlex.quote(PYTHON)+' '+shlex.quote(str(impl/name))+' "$@"\n')
            (STUBS/name).write_text(wrapper)
        for mode in ('state','cwd','both','exported','empty','key-only','file-alias',
                     'export-alias','empty-alias','empty-shellm-alias','config-dir','cwd-selector','default-home','legacy-home','layered-values'):
            c=Case('config-'+mode)
            state=c.root/'state'
            if mode=='default-home':
                c.env.pop('HEADLONG_HOME');state=c.root/'home'/'.headlong'
            elif mode=='legacy-home':
                c.env.pop('HEADLONG_HOME');c.env['SHELLM_HOME']=str(state)
            state.mkdir()
            config=("OPENROUTER_API_KEY='dummy & \\\\ key'\nSHELLM_MODEL=synthetic-model\n"
                    "SHELLM_API_URL=https://synthetic.invalid/v1\nLLM_API_URL=https://other.invalid/v1\n"
                    "LLM_API_KEY=dummy-generic\nLLM_PROVIDER=openai-compatible\n"
                    "LLM_ADAPTER=/synthetic/adapter\nLLM_OR_ONLY=synthetic-host\n"
                    "LLM_OR_ZDR=true\nLLM_RETRIES=0\nSHELLM_EFFORT=low\n"
                    + 'TRAJ_DIR='+shlex.quote(str(c.root/'unused-live-traj'))+'\n'
                    + 'LLM_USAGE_LEDGER='+shlex.quote(str(c.root/'unused-ledger'))+'\n')
            if mode=='key-only': config='OPENAI_API_KEY=dummy-openai\n'
            if mode=='file-alias': config=config.replace('SHELLM_API_URL=https://synthetic.invalid/v1\n','')
            if mode in ('cwd','cwd-selector'):
                (c.root/'.env').write_text(config)
            else: (state/'.env').write_text(config)
            if mode=='layered-values':
                (c.root/'.env').write_text('PROVIDER_ENDPOINT=https://layered.invalid/v1\n')
                (state/'.env').write_text(config.replace('https://synthetic.invalid/v1', '$PROVIDER_ENDPOINT'))
            if mode=='both': (c.root/'.env').write_text('SHELLM_MODEL=cwd-model\nOPENROUTER_API_KEY=dummy-cwd\n')
            if mode=='exported':
                c.env.update(OPENROUTER_API_KEY='dummy-exported',SHELLM_MODEL='exported-model',
                             SHELLM_API_URL='https://exported.invalid/v1',LLM_OR_ONLY='exported-host')
            if mode=='empty': c.env.update(OPENROUTER_API_KEY='',SHELLM_MODEL='',LLM_PROVIDER='',LLM_OR_ONLY='')
            if mode=='export-alias': c.env['LLM_API_URL']='https://export-alias.invalid/v1'
            if mode=='empty-alias': c.env['LLM_API_URL']=''
            if mode=='empty-shellm-alias': c.env['SHELLM_API_URL']=''
            if mode in ('config-dir','cwd-selector'):
                conf=c.root/'config-dir';conf.mkdir();(conf/'.env').write_text(config.replace('synthetic-model','config-model'))
                if mode=='config-dir': c.env['SHELLM_CONF_DIR']=str(conf)
                else: (c.root/'.env').write_text('SHELLM_CONF_DIR='+shlex.quote(str(conf))+'\n')
            reference={}
            for name in originals:
                script=prefixes[name]+'\nexport SHELLM_MODEL SHELLM_API_URL\n'+shlex.quote(PYTHON)+' -c '+shlex.quote(capture)
                r=subprocess.run(['/bin/bash','-c',script],cwd=c.root,env=c.env,text=True,capture_output=True,check=True)
                reference[name]=json.loads(r.stdout)
            c.run()
            for name in originals:
                actual=json.loads((c.root/(name+'-config.json')).read_text())
                assert all(actual[k]==reference[name][k] for k in keys), (mode,name,'configuration differs from original loader')
                if name=='shellm':
                    assert Path(actual['TRAJ_DIR']).is_relative_to(c.root/'runs')
                    assert actual['LLM_USAGE_LEDGER'] is None
            if mode=='key-only':
                before=json.loads((c.root/'shellm-before-config.json').read_text())
                assert before['OPENROUTER_API_KEY'] is None and before['LLM_API_URL'] is None
                assert before['SHELLM_API_URL'] is None
            assert not (c.root/'unused-live-traj').exists() and not (c.root/'unused-ledger').exists()
            # No copied config or secret-bearing files remain in disposable runs.
            assert not list((c.root/'runs').rglob('.env'))
    finally:
        for name,source in originals.items(): (STUBS/name).write_text(source)
check('repair3 actual loader configuration and alias precedence',operator_config)


def obsidian_refusal():
    c=Case('obsidian-refusal');c.skill('obsidian','Synthetic vault test only.')
    vault=c.root/'vault';vault.mkdir();sentinel=vault/'sentinel';sentinel.write_text('untouched')
    c.env['OBSIDIAN_VAULT']=str(vault)
    for command in ('compile','pool'):
        r=c.run(command,skill='obsidian',success=False)
        assert r.returncode!=0 and 'skip-list' in r.stderr
    assert not (c.root/'teacher-count').exists() and not (c.root/'shell-prompt').exists()
    assert sentinel.read_text()=='untouched'
check('repair3 obsidian refused before probing or model calls',obsidian_refusal)


def documented_output(kind, json_output=False):
    c=Case('documented-'+kind+('-json' if json_output else ''));phrase='Canonical documented success'
    if json_output: phrase=json.dumps({'result': phrase})
    c.skill('probe','Run probe.py\n```text\n'+phrase+'\n```\n','print('+repr(phrase)+')\n')
    c.tests([dict(name='documented',prompt='Execute the probe.',expect=kind,expect_contains=[phrase])])
    row=dict(type=kind,**({'stdout':phrase,'exit':0} if kind=='shell-output' else {'content':phrase}))
    (c.root/'trajectory.jsonl').write_text(json.dumps(row)+'\n')
    c.run();assert c.result()['tests'][0]['verification']=='VERIFIED'
for kind in ('observation','shell-output','final'):
    check('repair3 documented '+kind+' remains evidence',lambda kind=kind:documented_output(kind))
    check('repair3 documented JSON '+kind+' remains evidence',lambda kind=kind:documented_output(kind,True))


def probe_children(mode):
    import time
    c=Case('probe-child-'+mode)
    source=SC.read_text();helper=c.root/'bounded.sh'
    helper.write_text(source[source.index('_sc_bounded() {'):source.index('\nexecute_test() {')]+'\n_sc_bounded "$@"\n')
    child=c.root/'child.py';marker=c.root/'survived';pidfile=c.root/'child-pid'
    # Finite children ensure even the old, broken helper cannot leak a long-lived process.
    child.write_text('import time,pathlib\ntime.sleep(1)\npathlib.Path('+repr(str(marker))+').write_text("survived")\n')
    parent=c.root/'parent.py'
    parent.write_text('import subprocess,sys,pathlib,time\np=subprocess.Popen([sys.executable,'+repr(str(child))+'])\n'
                      'pathlib.Path('+repr(str(pidfile))+').write_text(str(p.pid))\n'
                      + ('time.sleep(1)\n' if mode=='timeout' else ''))
    start=time.monotonic()
    r=subprocess.run([os.environ.get('SC_TEST_BASH','/bin/bash'),str(helper),'0.2',PYTHON,str(parent)],
                     env=c.env,text=True,capture_output=True,timeout=4)
    elapsed=time.monotonic()-start
    # Wait past the finite child's write deadline before asserting it was killed.
    time.sleep(max(0,1.2-(time.monotonic()-start)))
    assert r.returncode==(124 if mode=='timeout' else 0),(r.returncode,r.stderr)
    assert elapsed<0.8 and not marker.exists(),(mode,elapsed,'descendant survived deadline')
for mode in ('normal','timeout'):
    check('repair3 probe descendants bounded on '+mode,lambda mode=mode:probe_children(mode))


def option_validation():
    c=Case('option-validation')
    for opt in ('--skill','--teacher-model','--num-tests','--max-iterations'):
        r=c.run(extra=(opt,),success=False)
        assert r.returncode!=0 and 'requires a value' in r.stderr and 'unbound variable' not in r.stderr
    for opt in ('--num-tests','--max-iterations'):
        for val in ('0','-1','abc','1.5','','9223372036854775808'):
            r=c.run(extra=(opt,val),success=False)
            assert r.returncode!=0 and opt in r.stderr
    assert not (c.root/'teacher-count').exists()
    c.tests([dict(name='case'+str(i),prompt='Run.',expect='final',expect_contains=[]) for i in range(3)])
    c.run(extra=('--num-tests','01','--max-iterations','02'))
    assert len(c.result()['tests'])==1
check('repair3 options validate before calls and test count is a ceiling',option_validation)


def harvest_minimum():
    c=Case('harvest-minimum');td=c.root/'history';td.mkdir()
    rows=[dict(type='reasoning',run_id='a',cmd='python3 probe.py'),
          dict(type='shell-output',run_id='a',stdout='Historical diagnostic output')]
    (td/'events.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
    c.env.update(SKILL_AUTO_HARVEST='1',SKILL_HARVEST_TRAJ_DIR=str(td),SKILL_HARVEST_MIN_COUNT='1')
    assert 'Historical diagnostic output' in json.loads(c.run('pool').stdout)
    c.env['SKILL_HARVEST_MIN_COUNT']='01'
    assert 'Historical diagnostic output' in json.loads(c.run('pool').stdout)
    for value in ('abc','','0','-1','1.5','9223372036854775808'):
        c.env['SKILL_HARVEST_MIN_COUNT']=value;r=c.run('pool',success=False)
        assert r.returncode!=0 and 'SKILL_HARVEST_MIN_COUNT' in r.stderr
check('repair3 history minimum diagnostic and valid history control',harvest_minimum)


def unchecked_literals():
    c=Case('unchecked-literals');c.output('Victory phrase stable','Victory phrase stable');c.env['RUNNER_RC']='1'
    c.run(success=False);r=c.result()['tests'][0]
    assert not r['pass'] and r['harness_error'] and r['expect_contains_missed']==[]
    assert r['expect_contains_unchecked']==['Victory phrase stable']
    del c.env['RUNNER_RC'];c.output('Different output','Different final');c.run();r=c.result()['tests'][0]
    assert r['expect_contains_missed']==['Victory phrase stable'] and r['expect_contains_unchecked']==[]
check('repair3 unchecked literals differ from checked misses',unchecked_literals)


def coarse_error_contract():
    c=Case('coarse-error');c.tests([dict(name='error',prompt='Verify probe rejects bad input.',expect='error',expect_contains=[])])
    rows=[dict(type='reasoning',cmd='ls missing'),dict(type='shell-output',exit=2,stderr='No such file'),
          dict(type='reasoning',cmd='python3 probe.py'),dict(type='shell-output',exit=0,stdout='Victory phrase stable')]
    (c.root/'trajectory.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
    c.run();assert c.result()['tests'][0]['verification']=='GREEN-NO-LITERALS'
    c.env['RUNNER_RC']='1';c.run(success=False);assert not c.result()['tests'][0]['pass']
check('repair3 coarse error contract is not behavioral verification or runner failure',coarse_error_contract)


def cache_commands():
    c=Case('cache-commands')
    # Case.run supplies --skill even to list; invoke the documented list form here.
    def listing():
        return subprocess.run([os.environ.get('SC_TEST_BASH','/bin/bash'),str(SC),'list'],env=c.env,cwd=c.root,
                              text=True,capture_output=True,check=True).stdout
    assert listing().strip()=='No compiled skills'
    c.run();assert listing().splitlines()==['probe']
    sentinel=c.root/'outside.md';sentinel.write_text('untouched')
    for command in ('show','clean'):
        for name in ('../outside','/outside','probe/../outside'):
            r=c.run(command,skill=name,success=False)
            assert r.returncode!=0 and 'invalid skill name' in r.stderr
        r=c.run(command,extra=('--skill',),success=False)
        assert r.returncode!=0 and 'requires a value' in r.stderr
    assert sentinel.read_text()=='untouched'
    c.run('show');c.run('clean');assert listing().strip()=='No compiled skills'
check('repair3 list and invalid show clean names',cache_commands)


def command_echo():
    c=Case('command-echo');phrase='echo Victory phrase stable'
    c.tests([dict(name='echo',prompt='Execute the probe.',expect='shell-output',expect_contains=[phrase])])
    rows=[dict(type='reasoning',cmd=phrase),dict(type='shell-output',stdout=phrase,exit=0)]
    (c.root/'trajectory.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
    c.run();assert not c.result()['tests'][0]['pass']
check('repair3 recorded command echo is not assertion evidence',command_echo)

print(f'{count-failed} regression checks passed, {failed} failed',flush=True)
sys.exit(bool(failed))
