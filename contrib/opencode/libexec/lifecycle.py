"""Identity-local lifecycle and admission gate; no provider calls."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

PACKAGE = Path(__file__).resolve().parent.parent
OWNER = 'headlong-contrib-opencode-v1\n'
ASSIGNMENT = re.compile(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=', re.MULTILINE)


def state_home(environment):
    explicit = environment.get('HEADLONG_HOME') or environment.get('SHELLM_HOME')
    if explicit:
        return Path(explicit).expanduser().resolve()
    home = Path(environment.get('HOME', str(Path.home())))
    modern, legacy = home / '.headlong', home / '.shellm'
    return legacy if not modern.exists() and legacy.is_dir() else modern


def caller_environment():
    environment = dict(os.environ)
    active = environment.get('IDENTITY_DIR')
    if environment.get('IDENTITY_NAME') and active:
        # Activation does not track export provenance. Do not treat assignments
        # inherited from an activated .env as explicit operator overrides.
        active = Path(active)
        if Path(environment.get('SHELLM_HOME', '/')) == active / '.shellm':
            environment.pop('SHELLM_HOME', None)
        configs = [active / '.env', state_home(environment) / '.env']
        if active.parent.name == '.identities':
            active_app = active.parent.parent
            configs.append(active_app / '.env')
            old_paths = {str(active_app / 'bin'), str(active_app / 'tools')}
            environment['PATH'] = os.pathsep.join(
                entry for entry in environment.get('PATH', os.defpath).split(os.pathsep)
                if entry not in old_paths)
        for config in configs:
            for key in configuration_keys(config):
                environment.pop(key, None)
        for key in list(environment):
            if (key.startswith(('IDENTITY_', 'SHELLM_TRAJ_', 'SHELLM_ENVS_', 'SHELLM_WORKDIRS_',
                                'SHELLM_BROKER_', 'SHELLM_CONF_', 'THINK_', 'CODING_AGENT_', 'OPENCODE_'))
                    or key in ['MEM_DIR', 'SKILLS_DIR', 'SKILLS_KERNEL_DIR', 'SKILLSRC',
                               'TRAJ_DIR', 'TRAJ_ID', 'ROOT_TRAJ_ID', 'THINKERS_DIR', 'CHATRC',
                               'SHELLM_MODEL', 'SHELLM_ENV', 'SHELLM_THINKER_ENV']
                    or key.endswith('_API_KEY')):
                environment.pop(key, None)
    environment.pop('BASH_ENV', None)
    environment.setdefault('HOME', str(Path.home()))
    return environment


def app_directory(identity=None, environment=None):
    # A path identifies its own checkout, even when a different app is active.
    if identity is not None and identity.parent.name == '.identities':
        return identity.parent.parent
    environment = caller_environment() if environment is None else environment
    explicit = environment.get('HEADLONG_APP_DIR') or environment.get('SHELLM_APP_DIR')
    if explicit:
        return Path(explicit).expanduser().resolve()
    if PACKAGE.parent.name == 'contrib':
        return PACKAGE.parent.parent
    installed_identity = PACKAGE.parent.parent
    if installed_identity.parent.name == '.identities':
        return installed_identity.parent.parent
    state = state_home(environment)
    recorded = state / 'app_dir'
    if recorded.is_file():
        return Path(recorded.read_text().strip()).expanduser().resolve()
    return state / 'app'


def resolve_identity(argument):
    # Bare names have one deterministic root. Use ./name for a relative path.
    path = Path(argument).expanduser()
    if '/' not in argument and argument not in ['.', '..']:
        path = app_directory() / '.identities' / argument
    return validate_identity(path)


def configuration_keys(path):
    return ASSIGNMENT.findall(path.read_text()) if path.is_file() else []


def source_environment(path, environment, identity_config=None):
    """Source trusted operator configuration privately, with Bash quoting."""
    bash = shutil.which('bash', path=environment.get('PATH', os.defpath))
    if not bash:
        fail('missing executable: bash')
    # Core activation's final cleanup can mask a nested .env syntax failure.
    if identity_config is not None and identity_config.is_file():
        check = subprocess.run([bash, '--noprofile', '--norc', '-p', '-n', str(identity_config)], env=environment,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if check.returncode:
            fail('could not load selected configuration; check .env/activate syntax')
    result = subprocess.run([
        bash, '--noprofile', '--norc', '-p', '-c',
        'set -a; source "$1" >/dev/null 2>&1 || exit 1; '
        'set +a; exec "$2" -c "import json,os; print(json.dumps(dict(os.environ)))"',
        'headlong-opencode-env', str(path), sys.executable,
    ], cwd=path.parent, env=environment, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
       text=True)
    if result.returncode:
        fail('could not load selected configuration; check .env/activate syntax')
    try:
        return json.loads(result.stdout)
    except ValueError:
        fail('could not read selected configuration; check .env/activate syntax')


def identity_environment(identity):
    environment = caller_environment()
    app = app_directory(identity, environment)
    state = state_home(environment)
    environment['PATH'] = os.pathsep.join([str(app / 'bin'), str(app / 'tools'),
                                          str(Path(environment['HOME']) / '.local/bin'),
                                          environment.get('PATH', os.defpath)])
    for path in [app / '.env', state / '.env']:
        keys = [key for key in configuration_keys(path) if key not in environment]
        if keys:
            loaded = source_environment(path, environment)
            for key in keys:
                if key in loaded:
                    environment[key] = loaded[key]
    activate = identity / 'activate'
    if activate.is_file():
        loaded = source_environment(activate, environment, identity / '.env')
        if not loaded.get('IDENTITY_NAME') or Path(loaded.get('IDENTITY_DIR', '/')).resolve() != identity:
            fail('selected activate did not set the selected identity paths')
        return loaded
    config = identity / '.env'
    return source_environment(config, environment) if config.is_file() else environment


def safe_text(value, environment):
    secrets = [secret for key, secret in environment.items()
               if key.endswith(('_API_KEY', '_TOKEN', '_SECRET', 'PASSWORD'))]
    try:
        config = json.loads(environment.get('OPENCODE_CONFIG_CONTENT', '{}'))
        def collect(item):
            if isinstance(item, dict):
                for key, child in item.items():
                    if key == 'apiKey' and isinstance(child, str):
                        secrets.append(child)
                    else:
                        collect(child)
            elif isinstance(item, list):
                for child in item:
                    collect(child)
        collect(config)
    except ValueError:
        pass
    for secret in sorted(filter(None, secrets), key=len, reverse=True):
        value = value.replace(secret, '<redacted-api-key>')
    return value


def fail(message):
    raise RuntimeError(message)


def exists(path):
    return os.path.lexists(path)


def owned(package):
    return (not package.is_symlink() and package.is_dir()
            and (package / '.owner').is_file()
            and (package / '.owner').read_text() == OWNER)


def registration_owned(registration, package):
    return registration.is_symlink() and os.readlink(registration) == '../extensions/opencode/skill'


def readiness(identity=None):
    try:
        environment = identity_environment(identity) if identity is not None else dict(os.environ)
    except RuntimeError as error:
        return 'opencode', [str(error)]
    except OSError:
        return 'opencode', ['could not load selected configuration; check .env/activate syntax and permissions']
    # Invalid inline configuration cannot be parsed for credential redaction.
    # Withhold executable metadata rather than exposing a credential-bearing path.
    try:
        config = json.loads(environment.get('OPENCODE_CONFIG_CONTENT', '{}'))
        if not isinstance(config, dict):
            raise ValueError
    except ValueError:
        return 'opencode', ['OPENCODE_CONFIG_CONTENT must be a valid JSON object; executable diagnostics withheld']
    problems = []
    if environment.get('SHELLM_THINKER_ENV', environment.get('SHELLM_ENV')) != 'local':
        problems.append('set SHELLM_THINKER_ENV=local in the dedicated local identity environment; Docker is unsupported')
    backend = environment.get('CODING_AGENT_OPENCODE_BIN', 'opencode')
    for name in ['bash', 'git', 'jq', 'python3', 'perl', 'traj', backend]:
        if not shutil.which(name, path=environment.get('PATH', os.defpath)):
            problems.append('missing executable: ' + safe_text(name, environment))
    return safe_text(shutil.which(backend, path=environment.get('PATH', os.defpath)) or backend,
                     environment), problems


def lock(path, operation):
    if path.is_symlink():
        fail('refusing symlink lock: ' + str(path))
    handle = path.open('a')
    fcntl.flock(handle, operation)
    return handle


def validate_identity(path):
    identity = path.resolve(strict=True)
    if not identity.is_dir() or not (identity / 'core_identity_prompt.md').is_file():
        fail('expected an existing Headlong identity with core_identity_prompt.md')
    for name in ['extensions', 'skills']:
        child = identity / name
        if child.is_symlink() or (exists(child) and not child.is_dir()):
            fail('refusing non-directory or symlink: ' + str(child))
    return identity


def main():
    mode = sys.argv[1]
    if mode == 'run':
        # Derive identity from this installed copy, never from caller environment.
        identity = validate_identity(PACKAGE.parent.parent)
        if PACKAGE != identity / 'extensions/opencode' or not owned(PACKAGE):
            fail('run the installed package, after explicit enablement')
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('command', choices=['install', 'enable', 'disable', 'status', 'doctor', 'uninstall'])
        parser.add_argument('--identity', required=True, help='identity name in the app checkout, or directory path')
        args = parser.parse_args(sys.argv[2:])
        identity = resolve_identity(args.identity)
    extensions = identity / 'extensions'
    extensions.mkdir(exist_ok=True)
    package = extensions / 'opencode'
    registration = identity / 'skills/opencode'
    marker = package / 'enabled'
    # Stable lock inode lives outside the removable package. Admission and
    # lifecycle transitions serialize; running tasks hold a separate shared lock.
    with lock(extensions / '.opencode.lifecycle.lock', fcntl.LOCK_EX):
        if mode == 'run':
            if not marker.is_file():
                fail('OpenCode integration is disabled for this identity')
            _, problems = readiness()
            if problems:
                fail('; '.join(problems))
            argv = sys.argv[2:]
            # Reject retained evidence beneath installation even through symlinks,
            # before the shell implementation creates anything.
            for index, flag in enumerate(argv):
                if flag not in ['--out', '--traj-dir']:
                    continue
                if index + 1 == len(argv):
                    fail(flag + ' requires a directory')
                target = Path(argv[index + 1]).resolve()
                if target == package or package in target.parents:
                    fail(flag + ' must be outside the installed package')
            if '--out' not in argv:
                target = Path(os.environ.get('TMPDIR', '/tmp')).resolve()
                if target == package or package in target.parents:
                    fail('temporary output directory must be outside the installed package')
            if os.environ.get('TRAJ_DIR'):
                target = Path(os.environ['TRAJ_DIR']).resolve()
                if target == package or package in target.parents:
                    fail('TRAJ_DIR must be outside the installed package')
            active = lock(extensions / '.opencode.runs.lock', fcntl.LOCK_SH)
        else:
            command = args.command
            if exists(package) and not owned(package):
                fail('refusing unrelated installation: ' + str(package))
            if command == 'install':
                if exists(package):
                    fail('already installed; disable and uninstall before replacing')
                if exists(registration):
                    fail('refusing existing skills/opencode registration')
                staging = Path(tempfile.mkdtemp(prefix='.opencode-install-', dir=extensions))
                try:
                    for name in ['bin', 'libexec', 'skill', 'docs']:
                        shutil.copytree(PACKAGE / name, staging / name, ignore=shutil.ignore_patterns('__pycache__'))
                    shutil.copy2(PACKAGE / 'README.md', staging / 'README.md')
                    digest = hashlib.sha256()
                    for file in sorted(staging.rglob('*')):
                        if file.is_file():
                            digest.update(str(file.relative_to(staging)).encode())
                            digest.update(file.read_bytes())
                    (staging / 'VERSION').write_text('sha256:' + digest.hexdigest() + '\n')
                    (staging / '.owner').write_text(OWNER)
                    staging.rename(package)
                finally:
                    if staging.exists():
                        shutil.rmtree(staging)
                print('Installed, disabled: ' + str(package))
                return 0
            if command in ['status', 'doctor']:
                backend, problems = readiness(identity)
                print(json.dumps(dict(installed=owned(package), enabled=marker.is_file(),
                                      revision=(package / 'VERSION').read_text().strip() if owned(package) else None,
                                      skill_registered=registration_owned(registration, package),
                                      backend=backend, environment='local only',
                                      readiness_issues=problems, authentication='not checked'), indent=2))
                return int(command == 'doctor' and bool(problems))
            if command == 'enable':
                if not owned(package):
                    fail('install the package first')
                # Fail closed even if this was previously enabled.
                marker.unlink(missing_ok=True)
                _, problems = readiness(identity)
                if problems:
                    if registration_owned(registration, package):
                        registration.unlink()
                    fail('; '.join(problems))
                if exists(registration) and not registration_owned(registration, package):
                    fail('refusing unrelated skills/opencode registration')
                registration.parent.mkdir(exist_ok=True)
                try:
                    if not exists(registration):
                        registration.symlink_to('../extensions/opencode/skill')
                    marker.touch()
                except BaseException:
                    if registration_owned(registration, package):
                        registration.unlink()
                    raise
                print('Enabled for ' + str(identity))
                return 0
            # Clear admission first; a registration conflict cannot leave calls enabled.
            if owned(package):
                marker.unlink(missing_ok=True)
            if exists(registration):
                if not registration_owned(registration, package):
                    fail('disabled; refusing unrelated skills/opencode registration; cleanup required')
                registration.unlink()
            if command == 'uninstall' and owned(package):
                try:
                    active = lock(extensions / '.opencode.runs.lock', fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    fail('disabled; admitted runs are still active; retry uninstall after they finish')
                with active:
                    shutil.rmtree(package)
                print('Uninstalled; evidence and credentials retained')
            else:
                print('Disabled; already admitted runs may finish')
            return 0
    # Keep shared admission lease across the entire task, without delaying disable.
    with active:
        return subprocess.call(['bash', str(package / 'libexec/coding-agent.sh'), *argv],
                               pass_fds=(active.fileno(),))


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, OSError) as error:
        print('headlong-opencode: ' + str(error), file=sys.stderr)
        sys.exit(2)
