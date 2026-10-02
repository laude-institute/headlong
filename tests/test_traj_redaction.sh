#!/usr/bin/env bash
# Credential redaction before trajectory records and output blobs are written.
# Uses real traj/context/shellm with synthetic credentials and a scripted llm.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
python3 - "$REPO" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
bash = shutil.which('bash')
real_jq = shutil.which('jq')
real_sed = shutil.which('sed')
names = ['ANTHROPIC_API_KEY', 'LLM_API_KEY', 'OPENAI_API_KEY',
         'OPENROUTER_API_KEY', 'GEMINI_API_KEY', 'OPENCODE_API_KEY']
keys = {n: 'fake-trajectory-' + n.lower() + '-0123456789abcdef' for n in names}
passed = failed = 0

def check(label, condition):
    global passed, failed
    if condition:
        passed += 1
        print('ok  ', label)
    else:
        failed += 1
        print('FAIL', label)

def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for k, v in value.items():
            yield k
            yield from strings(v)
    elif isinstance(value, list):
        for v in value:
            yield from strings(v)

def clean(value, values):
    return all(secret not in text for text in strings(value) for secret in values)

with tempfile.TemporaryDirectory(prefix='headlong-redaction-') as tmp:
    root = Path(tmp)
    toolbin = root / 'bin'
    shutil.copytree(repo / 'bin', toolbin)
    (toolbin / 'bash').symlink_to(bash)
    (toolbin / 'llm').write_text('#!/usr/bin/env bash\nexit 99\n')
    (toolbin / 'llm').chmod(0o755)
    home = root / 'home'
    home.mkdir()
    env = {'PATH': str(toolbin) + os.pathsep + os.environ['PATH'],
           'HOME': str(home), 'HEADLONG_HOME': str(home / '.headlong'),
           'SHELLM_HOME': str(home / '.headlong'), 'LANG': 'C.UTF-8',
           'SHELLM_ENV': 'local', 'SHELLM_MODEL': 'fake-model', **keys}

    def run(args, data=None, extra=None, cwd=None):
        return subprocess.run(args, input=data, text=True, env={**env, **(extra or {})},
                              cwd=cwd or root, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=60)

    def trajectory(label):
        td = root / label
        td.mkdir()
        p = run([str(toolbin / 'traj'), 'new', '--traj_dir', str(td)])
        assert p.returncode == 0, 'scratch trajectory creation failed'
        tid = p.stdout.splitlines()[0]
        p = run([str(toolbin / 'traj'), 'path', '--traj_dir', str(td), tid])
        assert p.returncode == 0
        return td, tid, Path(p.stdout.strip())

    def append(td, tid, payload, extra=None):
        return run([str(toolbin / 'traj'), 'append', '--traj_dir', str(td), tid],
                   json.dumps(payload), extra)

    # Every known provider value, including JSON escapes and glob characters.
    for variant in ['plain', 'escaped']:
        values = keys if variant == 'plain' else {
            n: 'fake-' + n.lower() + '-[*]?\\"/\n-end' for n in names}
        td, tid, jf = trajectory(variant)
        text = '\n'.join('KEY=' + v + '\nAuthorization: Bearer ' + v for v in values.values())
        for padding in [0, 800, 12000]:
            large = padding > 0
            payload = {'type': 'shell-output', 'stdout': 'safe padding\n' * padding + text,
                       'stderr': 'safe stderr\n' * padding + text,
                       'feedback': text, 'nested': {'items': [text, False, 17, None]},
                       'safe': 'quotes " backslash \\ newline\nUnicode Ω and NUL\u0000 retained', 'exit': 0}
            p = append(td, tid, payload, {**values, 'SHELLM_STDOUT_INLINE_LIMIT': '64' if large else '4096'})
            check(variant + ': append succeeds', p.returncode == 0)
            row = json.loads(jf.read_text().splitlines()[-1])
            check(variant + ': inline record masks all six values', clean(row, values.values()))
            check(variant + ': non-secret text, types and structure survive',
                  row['safe'] == payload['safe'] and row['nested']['items'][1:] == [False, 17, None]
                  and row['type'] == 'shell-output' and row['exit'] == 0)
            if large:
                for field in ['stdout', 'stderr']:
                    blob = jf.parent / row[field + '_ref']
                    stored = blob.read_text()
                    check(variant + ': ' + field + ' blob masks all values', clean(stored, values.values()))
                    check(variant + ': ' + field + ' byte count describes stored bytes',
                          row[field + '_bytes'] == len(blob.read_bytes()))
                # show --full currently passes blob contents through argv;
                # exercise it below the OS argument limit. The larger case
                # separately covers append/replay above that limit.
                if padding == 800:
                    full = run([str(toolbin / 'traj'), 'show', '--traj_dir', str(td), p.stdout.strip(), '--full'])
                    check(variant + ': full blob read is clean',
                          full.returncode == 0 and clean(json.loads(full.stdout), values.values()))
        p = append(td, tid, {'type': 'feedback', 'content': text}, values)
        check(variant + ': feedback record is clean', p.returncode == 0 and
              clean(json.loads(jf.read_text().splitlines()[-1]), values.values()))
        replay = run([str(toolbin / 'context'), '--traj_dir', str(td), tid,
                      '--user-types', 'shell-output,feedback', '--prompt-limit', '1000000'])
        check(variant + ': later context replay is clean', replay.returncode == 0 and
              clean(json.loads(replay.stdout), values.values()))
        recap = run([str(toolbin / 'recap'), '--traj_dir', str(td), tid,
                     '--context', '--cached', '--raw-tail', '10', '--budget', '100000'])
        check(variant + ': cached recap feedback is clean', recap.returncode == 0 and
              'Authorization: Bearer' in recap.stdout and clean(recap.stdout, values.values()))

    td, tid, jf = trajectory('provided-id')
    p = append(td, tid, {'type': 'shell-output', 'step_id': keys['OPENAI_API_KEY'],
                        'stdout': 'safe output ' * 800})
    row = json.loads(jf.read_text().splitlines()[-1])
    check('caller-provided id, blob name and returned id are clean', p.returncode == 0 and
          p.stdout.strip() == row['step_id'] and clean(row, keys.values()) and
          all(clean(str(f), keys.values()) for f in jf.parent.rglob('*')))

    # Keep the existing shape policy, including multiline and nested content.
    td, tid, jf = trajectory('shapes')
    shape_values = ['ghp_' + 'a' * 30, 'xoxb-' + 'b' * 30, 'sk-' + 'c' * 30,
                    'github_pat_' + 'q' * 30, 'whsec_' + 'r' * 24,
                    'hf_' + 'd' * 30, 'AIza' + 'e' * 32, 'AKIA' + 'F' * 16,
                    'eyJ' + 'g' * 20 + '.' + 'h' * 20 + '.' + 'i' * 20,
                    'https://user:password@invalid.test', 'sk_live_' + 'j' * 20,
                    'npm_' + 'k' * 24, 'glpat-' + 'l' * 24, 'dckr_pat-' + 'm' * 24,
                    'SG.' + 'n' * 24 + '.' + 'o' * 24, 'SK' + 'a' * 32,
                    'key-' + 'p' * 24, 'aws_secret_access_key=fake-private-value']
    pem = '-----' + 'BEGIN RSA PRIVATE KEY-----\nfake-private-payload\n-----END RSA PRIVATE KEY-----'
    shape_values.append(pem)
    payload = {'type': 'thought', 'content': '\n'.join(shape_values),
               'nested': {'auth': 'abcdefghijklmnopqrstuvwx'},
               'literal': '{"auth": "abcdefghijklmnopqrstuvwx"}', 'safe': 'Keep this text.'}
    p = append(td, tid, payload)
    try:
        row = json.loads(jf.read_text().splitlines()[-1])
    except (ValueError, IndexError):
        row = {}
    check('shape redaction preserves valid trajectory JSON', p.returncode == 0 and bool(row))
    check('existing credential shapes are masked', bool(row) and clean(row, shape_values))
    check('nested and text Docker auth remain masked', bool(row) and
          clean(row, ['abcdefghijklmnopqrstuvwx']))
    check('shape redaction preserves ordinary text', row.get('safe') == payload['safe'])
    p = append(td, tid, {'type': 'thought', 'content': 'Before\n-----' +
                        'BEGIN PRIVATE KEY-----\nunterminated-private-payload\nlast-line'})
    try:
        row = json.loads(jf.read_text().splitlines()[-1])
    except (ValueError, IndexError):
        row = {}
    check('unterminated private key masks the remaining string', p.returncode == 0 and
          row.get('content') == 'Before\n<redacted:private-key>')

    # A sanitizer that emits unsafe/invalid output then fails must write nothing.
    shim = root / 'failure-bin'
    shim.mkdir()
    script = '''#!/usr/bin/env bash
case "$*" in
  *"def redact_string"*|-E*)
    cat >/dev/null
    case "$FAIL_MODE" in
      exit) printf '%s' "$OPENROUTER_API_KEY"; printf '%s' "$OPENROUTER_API_KEY" >&2; exit 23 ;;
      invalid) printf 'not-json'; exit 0 ;;
      empty) exit 0 ;;
    esac ;;
esac
exec "$REAL_FILTER" "$@"
'''
    for name in ['jq', 'sed']:
        (shim / name).write_text(script)
        (shim / name).chmod(0o755)
    for mode in ['exit', 'invalid', 'empty']:
        td, tid, jf = trajectory('failure-' + mode)
        before = jf.read_bytes()
        # Each wrapper delegates to its own real binary outside the redactor.
        for name, real in [('jq', real_jq), ('sed', real_sed)]:
            (shim / name).write_text(script.replace('"$REAL_FILTER"', json.dumps(real)))
        p = append(td, tid, {'type': 'shell-output', 'stdout': 'x' * 8000 + keys['OPENROUTER_API_KEY']},
                   {'PATH': str(shim) + os.pathsep + env['PATH'], 'FAIL_MODE': mode})
        check(mode + ': sanitizer failure is reported', p.returncode != 0)
        check(mode + ': JSONL remains unchanged', jf.read_bytes() == before)
        check(mode + ': no blob or temporary payload is created', not (jf.parent / 'blobs').exists())
        check(mode + ': no append lock remains', not Path(str(jf) + '.lock').exists())
        check(mode + ': failure output contains no credential', clean(p.stdout + p.stderr, keys.values()))

    # Real set-x execution, watchdog feedback, and the next model prompt.
    (toolbin / 'llm').write_text('''#!/usr/bin/env bash
main=0; mf=""
while [[ $# -gt 0 ]]; do
 case "$1" in
  --thinking) main=1; shift ;;
  --messages-file) mf="$2"; shift 2 ;;
  *) shift ;;
 esac
done
if [[ "$main" != 1 ]]; then printf '{}\\n'; exit 0; fi
n=$(( $(cat "$FAKE_LLM_DIR/count" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" > "$FAKE_LLM_DIR/count"
cp "$mf" "$FAKE_LLM_DIR/call-$n.json"
if [[ "$n" == 1 ]]; then cat "$FAKE_LLM_DIR/code"; else printf '```bash\\nFINAL=done\\n```\\n'; fi
''')
    (toolbin / 'llm').chmod(0o755)
    for label, prefix in [('default', ''), ('custom', "PS4='TRACE '\n")]:
        wd = root / ('shellm-' + label)
        wd.mkdir()
        code = prefix + '''printf '%0800d\\n' 0
curl() { :; }
set -x
KEY="$OPENROUTER_API_KEY"
curl -H "Authorization: Bearer $KEY" https://invalid.test
set +x
sleep 30
'''
        (wd / 'code').write_text('```bash\n' + code + '```\n')
        p = run([str(toolbin / 'shellm'), '--workdir', str(wd), '--max-iterations', '2',
                 '--env', 'local', 'synthetic credential trace'], extra={
                 'FAKE_LLM_DIR': str(wd), 'SHELLM_STDOUT_INLINE_LIMIT': '64',
                 'SHELLM_INACTIVITY_TIMEOUT': '2', 'SHELLM_INACTIVITY_MAX': '30'}, cwd=wd)
        check(label + ': real shellm run completes', p.returncode == 0 and (wd / 'call-2.json').is_file())
        rows = []
        for jf in (home / '.headlong/trajectories').rglob('trajectory.jsonl'):
            rows.extend(json.loads(line) for line in jf.read_text().splitlines())
        check(label + ': timeout feedback was exercised', any(r.get('timed_out') for r in rows)
              and any(r.get('type') == 'feedback' for r in rows))
        check(label + ': shell records and feedback are clean', clean(rows, keys.values()))
        blobs = list((home / '.headlong/trajectories').rglob('*.stdout'))
        check(label + ': real stdout blobs are clean', bool(blobs) and
              all(clean(f.read_text(), keys.values()) for f in blobs))
        capture = wd / 'call-2.json'
        check(label + ': the next model prompt is clean', capture.is_file() and
              clean(json.loads(capture.read_text()), keys.values()))

print('\n%d passed, %d failed' % (passed, failed))
sys.exit(1 if failed else 0)
PY
