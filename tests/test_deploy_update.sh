#!/usr/bin/env bash
# test_deploy_update.sh — offline old-to-new deploy and read-only diagnostics.
# Requires Python 3 and git; sudo, systemctl and HTTP are local stubs.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$REPO" <<'PY'
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
passed = failed = 0

def check(label, condition):
    global passed, failed
    if condition:
        passed += 1
        print('ok   ' + label, flush=True)
    else:
        failed += 1
        print('FAIL ' + label, flush=True)

with tempfile.TemporaryDirectory(prefix='headlong-deploy-test-') as td:
    root = Path(td)
    home = root / 'home'
    home.mkdir()
    app = home / 'app'
    units = root / 'etc/systemd/system'
    units.mkdir(parents=True)
    (root / 'etc/update-motd.d').mkdir()
    (root / 'etc/sudoers.d').mkdir()
    (root / 'etc/fstab').touch()
    (root / 'etc/audit/rules.d').mkdir(parents=True)
    (root / 'usr/local/bin').mkdir(parents=True)
    stub = root / 'stub'
    stub.mkdir()
    env = {'PATH': str(stub) + ':' + os.environ['PATH'], 'HOME': str(home),
           'HEADLONG_HOME': str(home / '.headlong'), 'SHELLM_HOME': str(home),
           'APP_DIR': str(app), 'UNIT_DST': str(units / 'headlong-web.service'),
           'TEST_ROOT': str(root), 'GIT_CONFIG_NOSYSTEM': '1',
           'GIT_TERMINAL_PROMPT': '0', 'LC_ALL': 'C'}

    def run(args, **kw):
        return subprocess.run([str(a) for a in args], env=env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=30, **kw)

    def git(path, *args):
        p = run(['git', '-C', path, *args])
        if p.returncode:
            raise RuntimeError('scratch git command failed: ' + p.stderr)
        return p.stdout.strip()

    def script(name, text):
        p = stub / name
        p.write_text('#!/usr/bin/env bash\n' + text)
        p.chmod(0o755)

    script('sudo', 'if [[ "${1:-}" == -u ]]; then shift 2; fi\nexec "$@"\n')
    script('systemctl', '''printf '%s\\n' "$*" >> "$TEST_ROOT/systemctl.log"
case "$1" in
    is-active) echo active ;;
    list-units) echo 'headlong-thinkers@test.service loaded active running' ;;
esac
''')
    script('curl', "printf '%s\\n' '{\"status\":\"ok\"}'\n")
    script('visudo', 'exit 0\n')
    script('augenrules', 'exit 0\n')
    script('mountpoint', 'exit 0\n')
    script('install', '''args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|-g) shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
exec ''' + shlex.quote(shutil.which('install')) + ' "${args[@]}"\n')
    # A portable sha256sum for native macOS's simulated deployment.
    script('sha256sum', '''python3 - "$1" <<'HASH'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest())
HASH
''')

    def rewrite(text):
        return text.replace('/etc/', str(root / 'etc') + '/').replace(
            '/usr/local/', str(root / 'usr/local') + '/').replace(
            '/opt/shellm/app', str(app))

    # A real local git pull replaces an already-running historical script.
    source = root / 'source'
    source.mkdir()
    git(source, 'init', '-q', '--initial-branch=main')
    git(source, 'config', 'user.email', 'test@example.invalid')
    git(source, 'config', 'user.name', 'Deploy test')
    (source / 'deploy').mkdir()
    # Copy deployment code only, excluding any local Terraform state/config.
    for path in (repo / 'deploy').iterdir():
        if path.is_file() and (path.suffix in ('.sh', '.service', '.timer') or
                               path.name in ('headlong-thinkersctl',
                                             'sudoers-headlong-thinkers',
                                             'audit-headlong-signals.rules')):
            target = source / 'deploy' / path.name
            target.write_text(rewrite(path.read_text()))
            target.chmod(path.stat().st_mode)
    latest = (source / 'deploy/update.sh').read_text()
    old = rewrite((repo / 'tests/fixtures/deploy-update-pre-guard.sh').read_text())
    additions = {}
    for name in ('check-deploy.sh', 'thinkers-sandbox.sh', 'split-bridge-env.sh',
                 'headlong-thinkers-silence@.service', 'headlong-thinkers-silence@.timer'):
        path = source / 'deploy' / name
        if path.exists():
            additions[name] = (path.read_bytes(), path.stat().st_mode)
            path.unlink()
    (source / 'deploy/update.sh').write_text(old)
    git(source, 'add', 'deploy')
    git(source, 'commit', '-qm', 'historical updater')
    old_commit = git(source, 'rev-parse', 'HEAD')
    p = run(['git', 'clone', '-q', source, app])
    if p.returncode:
        raise RuntimeError('scratch clone failed')
    (source / 'deploy/update.sh').write_text(latest)
    for name, (content, mode) in additions.items():
        path = source / 'deploy' / name
        path.write_bytes(content)
        path.chmod(mode)
    git(source, 'add', 'deploy')
    git(source, 'commit', '-qm', 'current updater')
    (units / 'headlong-web.service').write_text('[Service]\n')
    fake_bot = 'synthetic-bridge-bot-value'
    fake_app = 'synthetic-bridge-app-value'
    (app / '.env').write_text('HEADLONG_SANDBOX=1\nSLACK_BOT_TOKEN=' + fake_bot +
                             '\nSLACK_APP_TOKEN=' + fake_app + '\n')
    first = run(['bash', app / 'deploy/update.sh'])
    dropin = units / 'headlong-thinkers@.service.d/sandbox.conf'
    timer = units / 'headlong-thinkers-silence@.timer'
    check('historical updater reports Healthy after pulling new code',
          first.returncode == 0 and '==> Healthy:' in first.stdout)
    check('first update actually advances the checkout',
          git(app, 'rev-parse', 'HEAD') == git(source, 'rev-parse', 'HEAD'))
    check('historical updater leaves sandbox and silence timer missing',
          not dropin.exists() and not timer.exists())
    check('historical updater leaves bridge assignments unmigrated',
          'SLACK_APP_TOKEN=' in (app / '.env').read_text() and
          not (app / '.env.bridge').exists())

    helper = app / 'deploy/check-deploy.sh'

    def diagnose(*options):
        return run(['bash', helper, *options, app, home, units])

    def combined(p):
        return p.stdout + p.stderr

    def snapshot():
        return {str(p.relative_to(root)): p.read_bytes()
                for base in (app, root / 'etc') for p in base.rglob('*')
                if p.is_file()}

    before = snapshot()
    p = diagnose()
    check('old-to-new diagnostic exits pending', p.returncode == 1)
    check('diagnostic names missing sandbox configuration',
          'Sandbox is enabled, but its systemd configuration is missing.' in p.stdout)
    check('diagnostic names missing silence service and timer',
          'Silence check service is missing.' in p.stdout and
          'Silence check timer is missing.' in p.stdout)
    check('diagnostic identifies bridge assignments without values',
          'Slack bridge token assignments remain in the shared .env.' in p.stdout and
          fake_bot not in combined(p) and fake_app not in combined(p))
    check('diagnostic provides the update command',
          'sudo bash' in p.stdout and str(app / 'deploy/update.sh') in p.stdout)
    check('diagnostic leaves deployment and environment unchanged', snapshot() == before)

    # Fake only the operator script's cloud transport. The remote command
    # and the historical update's local git pull execute normally.
    laptop = root / 'laptop'
    laptop.mkdir()
    for name in ('status', 'update'):
        (laptop / name).write_text(rewrite((repo / 'deploy/scripts' / name).read_text()))
    (laptop / 'lib.sh').write_text('''set -euo pipefail
REPO_ROOT="$APP_DIR"
require_tools() { :; }
require_state() { :; }
require_aws() { :; }
instance_state() { echo running; }
instance_id() { echo test-instance; }
region() { echo test-region; }
info() { printf '%s\\n' "$*"; }
tf() { echo http://localhost:8080; }
tfvar() { echo main; }
is_persona_stack() { return 1; }
run_script_on_box() { bash -c "$1"; }
''')
    git(app, 'reset', '--hard', old_commit)
    operator = run(['bash', laptop / 'update'])
    check('operator update catches a successful historical updater skipping steps',
          operator.returncode != 0 and '==> Healthy:' in operator.stdout and
          'Sandbox is enabled, but its systemd configuration is missing.' in operator.stdout)
    check('operator update pulls new diagnostics before reporting pending steps',
          helper.exists() and 'Silence check timer is missing.' in operator.stdout)

    # Run the actual current updater through the same fake system commands.
    second = run(['bash', app / 'deploy/update.sh'])
    check('second update applies files and explicitly checks configuration',
          second.returncode == 0 and dropin.exists() and timer.exists() and
          'Deploy configuration: required files are installed.' in second.stdout)
    check('current update labels the HTTP check accurately',
          '==> Web application is responding:' in second.stdout and
          '==> Healthy:' not in second.stdout)
    check('second update runs bridge migration',
          (app / '.env.bridge').exists() and
          'SLACK_APP_TOKEN=' not in (app / '.env').read_text())
    p = diagnose()
    check('fully applied file configuration passes',
          p.returncode == 0 and 'required files are installed' in p.stdout)
    p = diagnose('--warnings-only')
    check('fully applied login check is quiet',
          p.returncode == 0 and not combined(p))

    rendered = diagnose('--render-motd')
    motd = root / 'login-check'
    motd.write_text(rendered.stdout)
    p = run(['bash', motd])
    check('rendered login check is quiet after deployment',
          rendered.returncode == 0 and p.returncode == 0 and not combined(p))
    installed_motd = root / 'etc/update-motd.d/61-headlong-deploy'
    check('updater installs an executable login check',
          installed_motd.is_file() and os.access(installed_motd, os.X_OK))
    p = run(['bash', installed_motd])
    check('installed login entry is quiet for applied configuration',
          p.returncode == 0 and not combined(p))

    quoted_app = root / "app's space $HOME"
    quoted_app.symlink_to(app, target_is_directory=True)
    quoted = run(['bash', helper, '--render-motd', quoted_app, home, units])
    motd.write_text(quoted.stdout)
    p = run(['bash', motd])
    check('login renderer quotes paths containing spaces, quotes and dollars',
          quoted.returncode == 0 and p.returncode == 0 and not combined(p))

    # The diagnostics inspect names only and never execute .env contents.
    sentinel = root / 'must-not-exist'
    (app / '.env').write_text('HEADLONG_SANDBOX=0\nEVIL=$(touch ' + str(sentinel) +
                             ')\n# SLACK_APP_TOKEN=' + fake_app + '\n')
    dropin.unlink(missing_ok=True)
    p = diagnose()
    check('deliberately disabled sandbox is a valid configuration', p.returncode == 0)
    check('diagnostics do not source the environment file', not sentinel.exists())
    check('commented credentials are ignored and never printed',
          'Slack bridge token assignments' not in p.stdout and fake_app not in combined(p))
    dropin.parent.mkdir(exist_ok=True)
    dropin.write_text('[Service]\n')
    p = diagnose()
    check('disabled sandbox with leftover configuration is pending',
          p.returncode == 1 and
          'Sandbox is disabled, but its systemd configuration is still installed.' in p.stdout)
    dropin.unlink()
    timer.unlink()
    p = run(['bash', motd])
    check('login warns about missing timer without failing login',
          p.returncode == 0 and 'Silence check timer is missing.' in p.stdout)
    p = run(['bash', installed_motd])
    check('installed login entry reads current configuration on each login',
          p.returncode == 0 and 'Silence check timer is missing.' in p.stdout)

    # Run the real operator status entrypoint through the fake transport.
    p = run(['bash', laptop / 'status'])
    check('operator status shows web response and missing deployment files',
          p.returncode == 0 and 'Silence check timer is missing.' in p.stdout and
          'deployed:' in p.stdout)

    (app / '.env').unlink()
    p = diagnose()
    check('no shared environment defaults to sandbox enabled',
          p.returncode == 1 and 'Sandbox is enabled' in p.stdout)
    (app / '.env').write_text('HEADLONG_SANDBOX=0\n')
    for key in ('SLACK_BOT_TOKEN', 'SLACK_APP_TOKEN', 'SLACK_CLI_XOXB', 'SLACK_CLI_XAPP'):
        (app / '.env').write_text('HEADLONG_SANDBOX=0\n' + key + '=' + fake_bot + '\n')
        p = diagnose()
        check('detects ' + key + ' by assignment name only',
              'Slack bridge token assignments remain' in p.stdout and fake_bot not in combined(p))
    (app / '.env').write_text('HEADLONG_SANDBOX=0\n')
    saved_sandbox = (app / 'deploy/thinkers-sandbox.sh').read_text()
    for result in ('exit 23', 'exit 0'):
        (app / 'deploy/thinkers-sandbox.sh').write_text(
            'echo ' + fake_bot + '\necho ' + fake_app + ' >&2\n' + result + '\n')
        p = diagnose()
        check('sandbox check ' + result + ' cannot claim configuration is installed',
              p.returncode == 2 and 'could not be checked' in p.stdout and
              fake_bot not in combined(p) and fake_app not in combined(p))
    (app / 'deploy/thinkers-sandbox.sh').write_text(saved_sandbox)
    (app / '.env').unlink()
    (app / '.env').mkdir()
    p = diagnose()
    check('directory-valued environment reports inspection failure', p.returncode == 2)
    (app / '.env').rmdir()
    (app / '.env').write_text('HEADLONG_SANDBOX=0\n')
    p = run(['bash', helper, app, home, root / 'missing-units'])
    check('missing systemd directory reports inspection failure', p.returncode == 2)

    # Pending files must not be hidden by a successful HTTP response.
    script('systemctl', '''case "$1" in
    is-active) echo active ;;
    list-units) : ;;
esac
''')
    script('tee', 'cat >/dev/null\n')
    third = run(['bash', app / 'deploy/update.sh'])
    check('update returns failure when required files remain missing',
          third.returncode != 0 and 'Web application is responding:' in third.stdout and
          'Silence check timer is missing.' in third.stdout)

print(f'\n{passed} passed, {failed} failed')
sys.exit(bool(failed))
PY
