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
    (root / 'home').mkdir()
    (root / 'state').mkdir()
    env = dict(os.environ, PATH=os.pathsep.join([str(ROOT / 'bin'), str(ROOT / 'tools'), os.environ['PATH']]),
               HOME=str(root / 'home'), HEADLONG_HOME=str(root / 'state'), SHELLM_HOME=str(root / 'state'),
               IDENTITY_DIR=str(root / '.identities'), SHELLM_THINKER_ENV='local')
    for key in ['IDENTITY_NAME', 'MEM_DIR', 'SKILLS_DIR', 'TRAJ_DIR', 'TRAJ_ID', 'ROOT_TRAJ_ID', 'SKILLS_KERNEL_DIR']:
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
    identity = root / '.identities/opencode-test'
    other = root / 'other'
    other.mkdir()
    (other / 'info.txt').write_text('name=other\n')
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

    def identity_prompt():
        return run([ROOT / 'tools/identity', 'prompt', '--identity-dir', identity], cwd=root).stdout

    run([ROOT / 'tools/identity', 'new', 'opencode-test'], cwd=root)
    assert (identity / 'info.txt').is_file()
    assert not (identity / 'core_identity_prompt.md').exists()
    persona = identity_prompt()
    assert persona.startswith('I am opencode-test,')
    skills_before = prompt()
    missing = dict(env, CODING_AGENT_OPENCODE_BIN='/missing/opencode')
    manage('install', env=missing)
    for name in ['arbitrary', 'persona-only', 'directory-marker']:
        invalid = root / name
        invalid.mkdir()
        if name == 'persona-only':
            (invalid / 'core_identity_prompt.md').touch()
        elif name == 'directory-marker':
            (invalid / 'info.txt').mkdir()
        assert 'info.txt' in manage('install', False, target=invalid).stderr
        assert not (invalid / 'extensions').exists()
    # The new marker must not bypass existing directory/symlink protections.
    redirected = root / 'redirected'
    redirected.mkdir()
    for name in ['extensions', 'skills']:
        child = other / name
        child.write_text('unrelated')
        assert 'non-directory or symlink' in manage('install', False, target=other).stderr
        assert child.read_text() == 'unrelated'
        child.unlink()
        child.symlink_to(redirected, target_is_directory=True)
        assert 'non-directory or symlink' in manage('install', False, target=other).stderr
        assert child.is_symlink() and not list(redirected.iterdir())
        child.unlink()

    manage('install', target=other, env=missing)
    assert (package / 'VERSION').read_text().startswith('sha256:')
    assert package.is_dir() and not registration.exists()
    installed = json.loads(manage('status', env=missing).stdout)
    assert installed['installed'] and not installed['enabled'] and not installed['skill_registered']
    assert identity_prompt() == persona and prompt() == skills_before
    assert not (identity / 'core_identity_prompt.md').exists()
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
    assert identity_prompt() == persona and not (identity / 'core_identity_prompt.md').exists()
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
    assert identity_prompt() == persona and not (identity / 'core_identity_prompt.md').exists()
    print('ok   real identity creation, optional persona, identity validation, lifecycle, isolation, discovery, retained evidence, active-run removal guard, large task, successful descendants')
