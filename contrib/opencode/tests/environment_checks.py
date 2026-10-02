"""Lifecycle configuration regressions; synthetic homes and no backend calls."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

PACKAGE = Path(__file__).resolve().parents[1]
ROOT = PACKAGE.parents[1]

with tempfile.TemporaryDirectory() as temporary:
    scratch = Path(temporary)
    home = scratch / 'home'
    app = scratch / 'app with spaces'
    state = scratch / 'state'
    elsewhere = scratch / 'elsewhere'
    runtime_tools = scratch / 'runtime-tools'
    for directory in [home / '.local/bin', app / 'bin', app / 'tools', state, elsewhere]:
        directory.mkdir(parents=True)
    runtime_tools.mkdir()
    for name in ['bash', 'python3', 'git', 'jq', 'perl', 'dirname', 'grep', 'cut']:
        executable = shutil.which(name)
        assert executable, 'test prerequisite: ' + name
        (runtime_tools / name).symlink_to(executable)
    # Model the layout of an installed checkout without copying all of core.
    (app / 'bin/shellm').touch()
    shutil.copy2(ROOT / 'bin/traj', app / 'bin/traj')
    shutil.copytree(PACKAGE, app / 'contrib/opencode', ignore=shutil.ignore_patterns('__pycache__'))
    manager = app / 'contrib/opencode/bin/headlong-opencode'
    backend = home / '.local/bin/opencode'
    backend.write_text('#!/bin/sh\nprintf called > "$HOME/backend-was-called"\nexit 99\n')
    backend.chmod(0o755)
    identity = app / '.identities/target'
    other = app / '.identities/other'
    activation = (ROOT / 'tools/identity').read_text().split("<<'ACTIVATE'\n", 1)[1].split('\nACTIVATE', 1)[0]
    for directory in [identity, other]:
        directory.mkdir(parents=True)
        (directory / 'info.txt').write_text('name=' + directory.name + '\n')
        # Keep the existing persona validation contract; PR #188 is independent.
        (directory / 'core_identity_prompt.md').touch()
        (directory / 'activate').write_text(activation)
    env = dict(HOME=str(home), PATH=str(runtime_tools), HEADLONG_HOME=str(state))
    count = 0

    def manage(command='doctor', target='target', success=True, caller=None, entry=manager):
        global count
        prefix = [sys.executable, str(entry), 'manage'] if entry.suffix == '.py' else [str(entry)]
        result = subprocess.run([*prefix, command, '--identity', str(target)],
                                cwd=elsewhere, env=caller or env, capture_output=True, text=True)
        assert (result.returncode == 0) == success, (command, result.returncode, result.stdout, result.stderr)
        assert 'synthetic-private-value' not in result.stdout + result.stderr
        count += 1
        return result

    # A name is relative to the checkout, never to cwd or IDENTITY_DIR.
    (app / '.env').write_text('SHELLM_THINKER_ENV=local\n')
    manage('install')
    installed = identity / 'extensions/opencode/bin/headlong-opencode'
    report = json.loads(manage().stdout)
    assert report['backend'] == str(backend) and not report['enabled']
    manage(entry=installed)
    manage(target=identity)
    manage(target=os.path.relpath(identity, elsewhere))
    manage(entry=PACKAGE / 'bin/headlong-opencode', caller=dict(env, HEADLONG_APP_DIR=str(app)))
    manage(entry=PACKAGE / 'bin/headlong-opencode', caller=dict(env, SHELLM_APP_DIR=str(app)))
    manage(entry=PACKAGE / 'bin/headlong-opencode',
           caller=dict(env, HEADLONG_APP_DIR=str(app), SHELLM_APP_DIR=str(scratch / 'wrong-app')))
    manage('enable', entry=installed)
    assert (identity / 'extensions/opencode/enabled').is_file()
    manage(target=identity, caller=dict(env, HEADLONG_APP_DIR=str(scratch / 'wrong-app')))

    # App defaults beat state defaults; identity assignments beat both and callers.
    (state / '.env').write_text('SHELLM_THINKER_ENV=docker\nCODING_AGENT_OPENCODE_BIN=/missing/state\n')
    manage(success=False)
    (identity / '.env').write_text('CODING_AGENT_OPENCODE_BIN=opencode\n')
    manage()
    (identity / '.env').write_text('SHELLM_THINKER_ENV=docker\n')
    manage(success=False, caller=dict(env, SHELLM_THINKER_ENV='local'))
    (identity / '.env').unlink()
    (state / '.env').write_text('SHELLM_THINKER_ENV=docker\n')
    manage()
    # Explicit clean-caller settings (including empty values) precede defaults.
    manage(success=False, caller=dict(env, SHELLM_THINKER_ENV='docker'))
    manage(success=False, caller=dict(env, SHELLM_THINKER_ENV=''))
    manage(success=False, caller=dict(env, CODING_AGENT_OPENCODE_BIN='/missing/explicit'))

    # Shell quoting, expansion, export and identity PATH work as in activation.
    (identity / '.env').write_text('export OPENROUTER_API_KEY="synthetic-private-value"\n'
                                 'export CODING_AGENT_OPENCODE_BIN="$HOME/.local/bin/opencode"\n'
                                 'echo "$OPENROUTER_API_KEY"\nset -x\n')
    manage()
    (identity / '.env').write_text('CODING_AGENT_OPENCODE_BIN=opencode\n')
    (other / '.env').write_text('SHELLM_THINKER_ENV=docker\nCODING_AGENT_OPENCODE_BIN=/missing/other\n')
    activated = json.loads(subprocess.check_output([
        'bash', '--noprofile', '--norc', '-c',
        'source "$1" >/dev/null 2>&1; python3 -c "import json,os; print(json.dumps(dict(os.environ)))"',
        'test-activation', str(other / 'activate')], env=env, text=True))
    manage(caller=activated)
    # Caller-local SHELLM_HOME is not the framework state home.
    manage(caller=dict(activated, SHELLM_HOME=str(other / '.shellm')))
    manage(caller=dict(activated, CODING_AGENT_OPENCODE_BIN='/missing/stale-export'))
    # A different checkout's defaults and binaries cannot supply target readiness.
    foreign_app = scratch / 'foreign-app'
    foreign_identity = foreign_app / '.identities/foreign'
    foreign_identity.mkdir(parents=True)
    (foreign_app / '.env').write_text('CODING_AGENT_OPENCODE_BIN=/missing/foreign-app\n')
    foreign = dict(activated, IDENTITY_NAME='foreign', IDENTITY_DIR=str(foreign_identity),
                   CODING_AGENT_OPENCODE_BIN='/missing/foreign-app')
    manage(caller=foreign)
    foreign_bin = foreign_app / 'bin'
    foreign_bin.mkdir()
    shutil.copy2(backend, foreign_bin / 'opencode')
    backend.rename(backend.with_suffix('.hidden'))
    foreign.pop('CODING_AGENT_OPENCODE_BIN')
    foreign['PATH'] = str(foreign_bin) + os.pathsep + env['PATH']
    assert 'missing executable: opencode' in json.loads(manage(success=False, caller=foreign).stdout)['readiness_issues']
    backend.with_suffix('.hidden').rename(backend)
    (identity / '.env').unlink()
    manage(caller=activated)

    # State-home aliases, precedence and the pre-rename fallback.
    (app / '.env').unlink()
    (state / '.env').write_text('SHELLM_THINKER_ENV=local\n')
    manage()
    legacy_caller = dict(env, SHELLM_HOME=str(state))
    legacy_caller.pop('HEADLONG_HOME')
    manage(caller=legacy_caller)
    manage(caller=dict(env, SHELLM_HOME=str(scratch / 'wrong-state')))
    (state / '.env').write_text('SHELLM_THINKER_ENV=docker\n')
    legacy = home / '.shellm'
    legacy.mkdir()
    (legacy / '.env').write_text('SHELLM_THINKER_ENV=local\n')
    default_caller = dict(HOME=str(home), PATH=env['PATH'])
    manage(caller=default_caller)
    modern = home / '.headlong'
    modern.mkdir()
    (modern / '.env').write_text('SHELLM_THINKER_ENV=docker\n')
    manage(success=False, caller=default_caller)
    manage(success=False)  # Explicit state home never silently falls back.

    # An identity PATH is authoritative, even when the caller has dependencies.
    (identity / '.env').write_text('SHELLM_THINKER_ENV=local\nPATH=/nonexistent\n')
    missing = json.loads(manage(success=False).stdout)['readiness_issues']
    assert 'missing executable: git' in missing and 'missing executable: traj' in missing
    (identity / '.env').unlink()
    hook = scratch / 'startup-hook'
    hook.write_text('echo synthetic-private-value\nexit 1\n')
    (state / '.env').write_text('SHELLM_THINKER_ENV=local\n')
    manage(caller=dict(env, BASH_ENV=str(hook)), entry=app / 'contrib/opencode/libexec/lifecycle.py')
    (state / '.env').write_text('SHELLM_THINKER_ENV=local\n'
                              'OPENROUTER_API_KEY=synthetic-private-value\n'
                              'CODING_AGENT_OPENCODE_BIN="$OPENROUTER_API_KEY/missing"\n')
    manage(success=False)
    (state / '.env').write_text('SHELLM_THINKER_ENV=local\n')

    # Standalone installed managers resolve a recorded checkout/state app.
    standalone = scratch / 'standalone/extensions/opencode'
    shutil.copytree(PACKAGE, standalone, ignore=shutil.ignore_patterns('__pycache__'))
    (state / 'app_dir').write_text(str(app) + '\n')
    manage(entry=standalone / 'bin/headlong-opencode')
    (state / 'app_dir').unlink()
    (state / 'app').symlink_to(app, target_is_directory=True)
    manage(entry=standalone / 'bin/headlong-opencode')

    # Safe diagnostics and fail-closed enablement; removal needs no configuration.
    (identity / '.env').write_text('SHELLM_THINKER_ENV=local\n'
                                 'OPENROUTER_API_KEY=synthetic-private-value\n'
                                 'CODING_AGENT_OPENCODE_BIN="$OPENROUTER_API_KEY/missing"\n')
    manage(success=False)
    (identity / '.env').write_text('SHELLM_THINKER_ENV=local\n'
                                 'PROVIDER_TOKEN=synthetic-private-value\n'
                                 'CODING_AGENT_OPENCODE_BIN="$PROVIDER_TOKEN/missing"\n')
    manage(success=False)
    (identity / '.env').write_text('SHELLM_THINKER_ENV=local\n'
                                 'OPENCODE_CONFIG_CONTENT=\'{"provider":{"test":{"options":{"apiKey":"synthetic-private-value"}}}}\'\n'
                                 'CODING_AGENT_OPENCODE_BIN=synthetic-private-value/missing\n')
    manage(success=False)
    manage('enable', success=False)
    assert not (identity / 'extensions/opencode/enabled').exists()
    assert not (identity / 'skills/opencode').exists()
    (identity / '.env').write_text('echo synthetic-private-value >&2\nBROKEN="unterminated\n')
    manage(success=False)
    manage('disable')
    manage('uninstall')
    manage('install')  # Missing or invalid configuration does not prevent installation.
    assert not (identity / 'extensions/opencode/enabled').exists()
    assert not (home / 'backend-was-called').exists()
    print('ok   lifecycle identity/environment regression: %d public calls' % count)
