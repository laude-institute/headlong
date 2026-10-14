"""Local Signal draft identity, dependency checks and never-attempted revisions."""
from contextlib import contextmanager
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path


def raw(payload):
    return json.dumps(payload, sort_keys=True, ensure_ascii=False).encode()


def directory():
    if not os.environ.get('IDENTITY_DIR'): raise ValueError('activated identity required for durable Signal staging')
    p = Path(os.environ['IDENTITY_DIR']) / '.state' / 'staged-signal'
    p.mkdir(parents=True, exist_ok=True, mode=0o700)
    return p


def path(request_id):
    return directory() / (hashlib.sha256(request_id.encode()).hexdigest() + '.json')


@contextmanager
def locked():
    # Serialize staging/revision/submission across IDs too: a second digest must
    # not race the first digest's item reservation. Kernel releases on crash.
    with (directory() / '.lock').open('a') as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def prepare_batch(payload):
    if set(payload) != {'request_id', 'target', 'items'} or not isinstance(payload['items'], list) or not 1 <= len(payload['items']) <= 16:
        raise ValueError('batch needs request_id, target and 1..16 items with key and path')
    sources, parts, keys = [], [], set()
    for item in payload['items']:
        if set(item) != {'key', 'path'} or not isinstance(item['key'], str) or not item['key'].strip() or item['key'] in keys:
            raise ValueError('batch items need unique stable source keys (use the primary URL)')
        p = Path(item['path']).resolve()
        if not p.is_file() or p.stat().st_size > 16384:
            raise ValueError('each news draft must be an existing UTF-8 file under 16 KiB')
        content = p.read_bytes(); part = content.decode('utf-8').strip()
        if not part: raise ValueError('empty news draft')
        sources.append({'key': item['key'], 'path': str(p), 'sha256': hashlib.sha256(content).hexdigest()})
        parts.append(part); keys.add(item['key'])
    result = {'request_id': payload['request_id'], 'target': payload['target'], 'message': '\n\n'.join(parts), 'draft_sources': sources}
    if len(raw(result)) > 32768: raise ValueError('batch exceeds signal-send input limit')
    return result


def validate_sources(payload):
    sources = payload.get('draft_sources')
    if sources is None: return
    prepared = prepare_batch({'request_id': payload['request_id'], 'target': payload['target'],
                              'items': [{'key': s['key'], 'path': s['path']} for s in sources]})
    if sources != prepared['draft_sources'] or payload['message'] != prepared['message']:
        raise ValueError('local draft dependencies changed; prepare the batch again, then revise the never-attempted staged request with its expected hash')


def stage(payload):
    validate_sources(payload)
    p = path(payload['request_id']); content = raw(payload)
    if p.exists():
        if p.read_bytes() != content:
            raise ValueError('local staged payload conflict; host was not called. Inspect staged sha256 and use signal-revise-staged only for a never-attempted draft')
    else:
        from custos_dream import atomic
        atomic(p, content)
        from custos_dream import write_json
        write_json(p.with_suffix('.created.json'), {'request_id': payload['request_id'], 'sha256': hashlib.sha256(content).hexdigest()})
    return p


def attempted(request_id):
    return path(request_id).with_suffix('.attempt.json')


def mark_attempt(payload, wire_payload):
    from custos_dream import write_json
    write_json(attempted(payload['request_id']), {'request_id': payload['request_id'], 'at': dt.datetime.now(dt.timezone.utc).isoformat(),
        'sha256': hashlib.sha256(raw(payload)).hexdigest(), 'wire_sha256': hashlib.sha256(raw({**wire_payload, 'action': 'signal-send'})).hexdigest()})


def revise(payload, call):
    if set(payload) != {'request_id', 'expected_sha256', 'replacement'}:
        raise ValueError('revision needs request_id, expected_sha256 and complete replacement payload')
    replacement = payload['replacement']
    if not isinstance(replacement, dict) or replacement.get('request_id') != payload['request_id']:
        raise ValueError('revision must retain the original request ID')
    with locked():
        p = path(payload['request_id'])
        old = p.read_bytes()
        if hashlib.sha256(old).hexdigest() != payload['expected_sha256']:
            raise ValueError('staged draft changed; inspect it again')
        if not p.with_suffix('.created.json').exists():
            raise ValueError('legacy stage has no never-attempted provenance; reconcile with the operator, do not revise or use another ID')
        if attempted(payload['request_id']).exists():
            raise ValueError('submission was attempted; revision forbidden even if host status is unknown')
        code, result = call({'action': 'status', 'request_id': payload['request_id']})
        if code != 200 or result != {'ok': False, 'error': 'unknown_request'}:
            raise ValueError('host does not confirm unknown_request; revision forbidden')
        validate_sources(replacement)
        from custos_dream import atomic
        backup = p.with_name(p.stem + '.before-' + payload['expected_sha256'])
        if not backup.exists(): atomic(backup, old)
        atomic(p, raw(replacement))
        return {'ok': True, 'origin': 'local-staging', 'request_id': payload['request_id'], 'sha256': hashlib.sha256(p.read_bytes()).hexdigest(),
                'meaning': 'Never-attempted draft revised with preimage retained. Nothing submitted.'}


def check_duplicate_items(payload, call):
    """A submitted/uncertain earlier batch owns its items. Never infer success."""
    wanted = {s['key'] for s in payload.get('draft_sources', [])}
    if not wanted or payload.get('delivery_kind') == 'correction': return
    from custos_dream import read_json
    previous_items = list(read_json(directory() / 'legacy-news-history.json', []))
    for previous in directory().glob('*.attempt.json'):
        old = json.loads(previous.with_name(previous.name.replace('.attempt.json', '.json')).read_text())
        previous_items.append({'request_id': old['request_id'], 'keys': [s['key'] for s in old.get('draft_sources', [])]})
    for old in previous_items:
        if old['request_id'] == payload['request_id']: continue
        if not wanted.intersection(old['keys']): continue
        code, result = call({'action': 'status', 'request_id': old['request_id']})
        if code != 200 or result.get('phase') not in {'blocked', 'suppressed', 'failed', 'withdrawn', 'expired'}:
            raise ValueError('news item already submitted or unresolved in ' + old['request_id'] + '; inspect its receipt, do not repeat it in a new digest')


def associate_goal(request_id, goal_id):
    """Keep task linkage across retries that omit the convenience --goal flag."""
    from custos_dream import read_json, write_json
    p = path(request_id).with_suffix('.goal.json')
    old = read_json(p, {})
    if old.get('goal_id') and goal_id and old['goal_id'] != goal_id:
        raise ValueError('request is already associated with another goal')
    if goal_id and not old:
        write_json(p, {'goal_id': goal_id})
    return old.get('goal_id') or goal_id
