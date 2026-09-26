"""Offline public-entrypoint regression tests, including large task transport."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

PACKAGE = Path(__file__).resolve().parents[1]
ROOT = PACKAGE.parents[1]
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    env = dict(os.environ, PATH=str(ROOT / 'bin') + os.pathsep + os.environ['PATH'],
               SHELLM_THINKER_ENV='local')
    for key in ['TRAJ_DIR', 'TRAJ_ID', 'SKILLS_KERNEL_DIR']:
        env.pop(key, None)
    backend = root / 'backend'
    backend.write_text('''#!/usr/bin/env python3
import os, pathlib, subprocess, sys, time
prompt = sys.stdin.read()
pathlib.Path(os.environ['PROMPT_CAPTURE']).write_text(prompt)
pathlib.Path('delegated.txt').write_text('implemented')
if os.environ.get('BACKGROUND'):
    subprocess.Popen([sys.executable, '-c', "import pathlib,time,sys; time.sleep(3); pathlib.Path(sys.argv[1]).write_text('leaked')", os.environ['BACKGROUND']])
if os.environ.get('HOLD'):
    pathlib.Path(os.environ['HOLD']).touch()
    time.sleep(3)
''')
    backend.chmod(0o755)
    env.update(CODING_AGENT_OPENCODE_BIN=str(backend), PROMPT_CAPTURE=str(root / 'prompt'))
    manager = PACKAGE / 'bin/headlong-opencode'
    identity = root / 'identity'
    other = root / 'other'
    for item in [identity, other]:
        item.mkdir()
        (item / 'core_identity_prompt.md').touch()
    package = identity / 'extensions/opencode'
    wrapper = package / 'bin/coding-agent'
    registration = identity / 'skills/opencode'

    def run(argv, success=True, **kwargs):
        result = subprocess.run([str(x) for x in argv], env=kwargs.pop('env', env),
                                text=True, capture_output=True, **kwargs)
        assert (result.returncode == 0) == success, (argv, result.returncode, result.stdout, result.stderr)
        return result

    def manage(command, success=True, target=identity, **kwargs):
        return run([manager, command, '--identity', target], success, **kwargs)

    def prompt(target=identity):
        return run(['skills', 'prompt'], env=dict(env, SKILLS_DIR=str(target / 'skills')), cwd=root).stdout

    missing = dict(env, CODING_AGENT_OPENCODE_BIN='/missing/opencode')
    manage('install', env=missing)
    manage('install', target=other, env=missing)
    assert (package / 'VERSION').read_text().startswith('sha256:')
    assert package.is_dir() and not registration.exists()
    assert 'opencode' not in prompt()
    manage('install', False)
    assert 'missing executable' in manage('doctor', False, env=missing).stdout
    manage('enable', False, env=missing)
    assert not registration.exists() and not (package / 'enabled').exists()
    out = root / 'disabled-output'
    run([wrapper, '--out', out], False)
    assert not out.exists()
    manage('enable')
    manage('enable')
    assert 'opencode' in prompt() and 'opencode' not in prompt(other)
    assert json.loads(manage('status').stdout)['enabled']
    # Evidence paths through symlinks must fail before creating directories.
    alias = root / 'alias'
    alias.symlink_to(package, target_is_directory=True)
    for flag in ['--out', '--traj-dir']:
        run([wrapper, flag, alias / 'evidence'], False)
        assert not (package / 'evidence').exists()
    run([wrapper], False, env=dict(env, SHELLM_THINKER_ENV='docker'))

    repo = root / 'repo'
    repo.mkdir()
    run(['git', '-C', repo, 'init', '-q'])
    (repo / 'source').write_text('base')
    run(['git', '-C', repo, 'add', '.'])
    run(['git', '-C', repo, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'base'])
    task = root / 'task.md'
    task_text = 'Large task with full retention.\n' * 10000 + 'END OF TASK\n'
    task.write_text(task_text)
    out = root / 'large-task'
    invocation = [wrapper, '--repo', repo, '--task-file', task, '--verify', 'test -f delegated.txt', '--out', out]
    env['BACKGROUND'] = str(root / 'executor-leak')
    result = json.loads(run(invocation).stdout)
    assert result['task'] == task_text and result['status'] == 'candidate' and result['accepted'] is False
    assert task_text in (root / 'prompt').read_text()
    records = [json.loads(line) for file in (out / 'trajectories').rglob('trajectory.jsonl') for line in file.read_text().splitlines()]
    assert any(record.get('type') == 'delegation' and record.get('task') == task_text for record in records)
    assert any(record.get('type') == 'delegation-result' and record.get('task') == task_text for record in records)
    time.sleep(3)
    assert not (root / 'executor-leak').exists()
    env.pop('BACKGROUND')
    verify_marker = root / 'verify-leak'
    verifier = root / 'verifier.py'
    verifier.write_text("import subprocess,sys\nsubprocess.Popen([sys.executable, '-c', \"import pathlib,time; time.sleep(3); pathlib.Path(" + repr(str(verify_marker)) + ").touch()\"])\n")
    invocation[invocation.index('--verify') + 1] = 'python3 ' + str(verifier)
    invocation[-1] = root / 'verify-background'
    assert json.loads(run(invocation).stdout)['status'] == 'candidate'
    time.sleep(3)
    assert not verify_marker.exists()

    env['HOLD'] = str(root / 'admitted')
    invocation[-1] = root / 'active-run'
    with (root / 'active.stdout').open('w') as stdout, (root / 'active.stderr').open('w') as stderr:
        process = subprocess.Popen([str(x) for x in invocation], env=env, stdout=stdout, stderr=stderr)
        deadline = time.monotonic() + 15
        while not Path(env['HOLD']).exists():
            assert process.poll() is None and time.monotonic() < deadline
            time.sleep(.05)
        manage('disable', env=missing)
        assert 'opencode' not in prompt()
        run([wrapper, '--out', root / 'after-disable'], False)
        assert not (root / 'after-disable').exists()
        assert 'still active' in manage('uninstall', False, env=missing).stderr
        assert process.wait(timeout=20) == 0
    env.pop('HOLD')
    manage('disable')
    manage('enable')
    assert 'opencode' in prompt()
    # Ownership conflicts never delete another skill, even during removal.
    registration.unlink()
    registration.mkdir()
    (registration / 'keep').touch()
    manage('enable', False)
    assert not (package / 'enabled').exists()
    manage('disable', False)
    manage('uninstall', False)
    assert (registration / 'keep').exists()
    (registration / 'keep').unlink()
    registration.rmdir()
    unrelated = root / 'unrelated'
    unrelated.mkdir()
    registration.symlink_to(unrelated)
    manage('enable', False)
    manage('uninstall', False)
    assert unrelated.is_dir()
    registration.unlink()
    # A marker write failure rolls back the newly created registration.
    if os.geteuid() != 0:
        package.chmod(0o555)
        try:
            manage('enable', False)
            assert not registration.exists()
        finally:
            package.chmod(0o755)
    manage('enable')
    credentials = root / 'provider-credentials'
    credentials.write_text('retained')
    manage('uninstall', env=missing)
    assert credentials.read_text() == 'retained'
    assert not package.exists() and not registration.exists()
    assert Path(result['patch_ref']).exists() and Path(result['worktree']).exists()
    assert (out / 'trajectories').is_dir()
    run(['git', '-C', repo, 'show-ref', '--verify', 'refs/heads/' + result['candidate_branch']])
    manage('uninstall', env=missing)
    manage('install')
    assert not (package / 'enabled').exists()
    print('ok   lifecycle, isolation, discovery, retained evidence, active-run removal guard, large task, successful descendants')
