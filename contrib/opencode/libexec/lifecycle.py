"""Identity-local lifecycle and admission gate; no provider calls."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

PACKAGE = Path(__file__).resolve().parent.parent
OWNER = 'headlong-contrib-opencode-v1\n'


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


def readiness():
    problems = []
    if os.environ.get('SHELLM_THINKER_ENV', os.environ.get('SHELLM_ENV')) != 'local':
        problems.append('set SHELLM_THINKER_ENV=local in the dedicated local identity environment; Docker is unsupported')
    backend = os.environ.get('CODING_AGENT_OPENCODE_BIN', 'opencode')
    for name in ['bash', 'git', 'jq', 'python3', 'perl', 'traj', backend]:
        if not shutil.which(name):
            problems.append('missing executable: ' + name)
    return backend, problems


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
        parser.add_argument('--identity', required=True, type=Path)
        args = parser.parse_args(sys.argv[2:])
        identity = validate_identity(args.identity)
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
                backend, problems = readiness()
                print(json.dumps(dict(installed=owned(package), enabled=marker.is_file(),
                                      revision=(package / 'VERSION').read_text().strip() if owned(package) else None,
                                      skill_registered=registration_owned(registration, package),
                                      backend=shutil.which(backend) or backend, environment='local only',
                                      readiness_issues=problems, authentication='not checked'), indent=2))
                return int(command == 'doctor' and bool(problems))
            if command == 'enable':
                if not owned(package):
                    fail('install the package first')
                # Fail closed even if this was previously enabled.
                marker.unlink(missing_ok=True)
                _, problems = readiness()
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
