"""Receipt-aware Signal contact eligibility. No sending or retrying here."""
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

UTC = dt.timezone.utc
UNSENT = {'blocked', 'suppressed', 'failed', 'withdrawn', 'expired'}

MEANING = ('ok controls the eligibility decision; a null resume_at means no deadline is set '
           'and is not a block on its own.')


def _signal(result, state):
    """Attach explicit result state to a Signal eligibility decision."""
    meaning = MEANING
    if state == 'cooldown':
        meaning += ' resume_at is the cooldown deadline for this conversation.'
    result['state'] = state
    result['meaning'] = meaning
    return result


def route_for(target):
    return 'signal-' + hashlib.sha256(target.encode()).hexdigest()[:24]


def canonical(value, contacts):
    matches = [c['target'] for c in contacts if isinstance(c, dict) and c.get('target') and
               value.casefold() in {c['target'].casefold(), route_for(c['target']), str(c.get('label', '')).casefold()}]
    if len(set(matches)) == 1:
        target = matches[0]
        return target, route_for(target)
    if value.startswith(('dm:', 'group:', 'signal-')):
        raise ValueError('Signal conversation is not uniquely allowlisted; inspect signal-contacts')
    return None, value


def timestamp(value):
    if isinstance(value, (int, float)):
        return float(value) / (1000 if value > 100000000000 else 1)
    parsed = dt.datetime.fromisoformat(str(value).replace('Z', '+00:00'))
    if parsed.tzinfo is None: parsed = parsed.replace(tzinfo=UTC)
    return parsed.timestamp()


def iso(value):
    return dt.datetime.fromtimestamp(value, UTC).isoformat()


def reference(row):
    # Older native message indexes retained request_id but dropped delivered_by.
    # Outbound action records carry request_id; native replies use step_id.
    if row.get('request_id') and row.get('delivered_by', 'custos-actions') == 'custos-actions':
        return 'action:' + row['request_id']
    return 'outbox:' + row['step_id'] if row.get('step_id') else None


def metadata(row, key):
    if '_' + key in row: return row['_' + key]
    match = re.search(r'"' + key + r'"\s*:\s*"([^"\n]+)"', row.get('content', ''))
    return match[1] if match else ''


def evaluate(rows, target, route, hours, cross, receipt, now, me='custos'):
    """Pure decision with injected clock and read-only receipt lookup.

    Definitively unsent rows have no social effect. An unknown/in-flight send
    reserves its conversation even after a reply or the ordinary time window.
    """
    base = {'applicable': True, 'target': target, 'route': route, 'hours': hours,
            'mode': 'social' if cross else 'mind', 'resume_at': None,
            'channel': 'signal', 'receipt_namespaces': ['action', 'outbox']}
    messages = [r for r in rows if not r.get('_reaction') and 'Signal reaction (ambient event' not in r.get('content', '')]
    groups = {r.get('from') for r in messages if r.get('to') == me and metadata(r, 'scope') == 'group'}
    aci = target[3:] if target.startswith('dm:') else ''
    groups = {g for g in groups if any(r.get('from') == g and metadata(r, 'aci') == aci for r in messages)} if aci and cross else set()
    relevant = {route} | groups
    cache = {}; effective = []; reserved = []
    for row in messages:
        outgoing = row.get('from') == me and row.get('to') in relevant
        incoming = row.get('to') == me and (row.get('from') in relevant or metadata(row, 'aci') == aci)
        if not outgoing and not incoming: continue
        r = dict(row)
        try: r['_time'] = timestamp(row.get('ts'))
        except (ValueError, TypeError, OverflowError):
            if outgoing: reserved.append({'reference': reference(row), 'phase': 'invalid-message-time', 'route': row.get('to')})
            continue
        if outgoing:
            ref = reference(row)
            if ref not in cache:
                cache[ref] = receipt(ref) if ref else {'phase': 'unknown'}
            result = cache[ref]; phase = result.get('phase', 'unknown'); proof = result.get('receipt') or {}
            if phase in UNSENT: continue
            # A native log line without reply correlation cannot enter the
            # bridge outbox. Older chat versions wrote such unsendable lines.
            # Only ignore it after the host confirms there is no outbox record.
            if (phase == 'unknown' and result.get('record_found') is False and
                    not row.get('reply_to') and not row.get('request_id') and row.get('source') == 'chat'):
                continue
            if isinstance(proof, dict) and proof.get('converted_to_reaction'): continue
            success = (phase == 'submitted' and isinstance(proof, dict) and proof.get('timestamp') and proof.get('results')
                       and all(isinstance(p, dict) and p.get('type') == 'SUCCESS' for p in proof['results']))
            if not success:
                reserved.append({'reference': ref, 'phase': phase, 'route': row.get('to'),
                                 '_missing': result.get('record_found') is False, '_time': r['_time']}); continue
            try: r['_time'] = timestamp(proof['timestamp'])
            except (ValueError, TypeError, OverflowError):
                reserved.append({'reference': ref, 'phase': 'invalid-receipt-time', 'route': row.get('to')}); continue
        effective.append(r)
    # Missing old log-to-spool records are distinct from a recorded uncertain
    # attempt. Once a later *confirmed* send in that same room has superseded
    # their cadence window, they cannot reserve the entire conversation forever.
    # This supplies no delivery evidence and never authorizes retrying that text.
    historical = [r for r in reserved if r.get('_missing') and r['phase'] == 'unknown' and
                  r['_time'] + max(hours, 12) * 3600 <= now and any(
                      e.get('from') == me and e.get('to') == r['route'] and e['_time'] > r['_time']
                      for e in effective)]
    if historical: base['historical_untracked'] = len(historical)
    reserved = [{k: v for k, v in r.items() if not k.startswith('_')} for r in reserved if r not in historical]
    if reserved:
        return _signal({**base, 'ok': False, 'reason': 'delivery-unresolved', 'reservations': reserved,
                        'error': 'A Signal send is in flight or its acceptance is unknown; reconcile its receipt before another send.'},
                       'unresolved')
    if hours <= 0: return _signal({**base, 'ok': True}, 'open')
    deadlines = []
    for room in relevant:
        conv = [r for r in effective if (r.get('from') == me and r.get('to') == room) or (r.get('from') == room and r.get('to') == me)]
        last = max(reversed(conv), key=lambda r: r['_time'], default=None)
        if not last or last.get('from') != me or last['_time'] + hours * 3600 <= now: continue
        if room != route and any(r.get('to') == me and metadata(r, 'aci') == aci and
                                 (r['_time'] > last['_time'] or r['_time'] > now - 3600) for r in effective): continue
        deadlines.append((last['_time'] + hours * 3600, room))
    if deadlines:
        end, room = max(deadlines)
        return _signal({**base, 'ok': False, 'reason': 'cooldown', 'anchor_route': room, 'resume_at': iso(end),
                        'error': ('you spoke last in this conversation; ' if room == route else 'your last group message is unanswered. Do not move the ask to a DM; ') + 'guard reopens at ' + iso(end) +
                                 ' unless an eligible reply arrives first. Stage the text; do not sleep, loop or poll, or change channels.'},
                       'cooldown')
    return _signal({**base, 'ok': True}, 'open')


def indexed_rows(trajectory):
    """Incremental receipt index from raw message metadata, atomically cached.

    Older chat indexes lost action request IDs. Reusing those indexes would
    misidentify delivered actions as missing native outbox entries. This derived
    index has no authority and is safe to delete/rebuild; it never edits the log.
    """
    from custos_dream import write_json
    trajectory = Path(trajectory)
    path = trajectory.parent / 'signal-guard-index.json'
    with path.with_suffix('.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        stat = trajectory.stat()
        previous = json.loads(path.read_text()) if path.exists() else {}
        with trajectory.open('rb') as stream:
            header = hashlib.sha256(stream.readline()).hexdigest()
            valid = previous.get('version') == 1 and previous.get('header') == header and previous.get('inode') == stat.st_ino and previous.get('offset', 0) <= stat.st_size
            rows = previous.get('rows', []) if valid else []
            offset = previous.get('offset', 0) if valid else 0
            stream.seek(offset)
            while True:
                line = stream.readline()
                if not line or not line.endswith(b'\n'): break
                offset = stream.tell()
                if b'"message"' not in line: continue
                try: row = json.loads(line)
                except ValueError: continue
                if row.get('type') != 'message' or not any(str(row.get(k, '')).startswith('signal-') for k in ('from', 'to')): continue
                slim = {k: row[k] for k in ('step_id', 'ts', 'from', 'to', 'source', 'reply_to', 'request_id', 'delivered_by', 'social_intent') if k in row}
                slim.update(_aci=metadata(row, 'aci'), _scope=metadata(row, 'scope'),
                            _reaction='Signal reaction (ambient event' in row.get('content', ''))
                rows.append(slim)
        if not valid or offset != previous.get('offset'):
            write_json(path, {'version': 1, 'header': header, 'inode': stat.st_ino, 'offset': offset, 'rows': rows})
        return rows


def check(value, hours=None, cross=None):
    from custos_actions_client import call
    from custos_memory import delivery_status
    status, data = call({'action': 'signal-contacts'}, timeout=3)
    if status != 200 or not isinstance(data, dict) or not data.get('ok'):
        raise ValueError('Signal contacts unavailable; eligibility is unknown')
    target, route = canonical(value, data.get('destinations') or data.get('contacts') or [])
    if target is None:
        return {'applicable': False, 'ok': True, 'channel': 'native', 'state': 'not-applicable',
                'receipt_namespaces': [],
                'meaning': 'no Signal send or receipt is involved; this target is not an allowlisted Signal conversation.'}
    policy = json.loads((Path(os.environ['IDENTITY_DIR']) / 'social-policy.json').read_text())
    cross = os.environ.get('CHAT_GUARD_CROSS_ROOM') == '1' if cross is None else cross
    if hours is None:
        hours = int(os.environ.get('CHAT_DOUBLE_TEXT_GUARD_HOURS') or policy.get('initiate_after_hours' if cross else 'mind_double_text_hours', 12 if cross else 2))
    if type(hours) is not int or hours < 0: raise ValueError('invalid contact window')
    root = os.environ.get('ROOT_TRAJ_ID') or os.environ.get('TRAJ_ID')
    if not root: raise ValueError('trajectory unavailable; contact eligibility is unknown')
    lookup = subprocess.run(['traj', 'path', root], capture_output=True, text=True, timeout=30, check=True)
    rows = indexed_rows(lookup.stdout.strip())
    # Bulk read keeps the initial/history reconciliation bounded in network calls.
    groups = {r.get('from') for r in rows if r.get('to') == os.environ.get('IDENTITY_NAME', 'custos') and metadata(r, 'scope') == 'group'} if cross else set()
    refs = sorted({reference(r) for r in rows if r.get('from') == os.environ.get('IDENTITY_NAME', 'custos') and r.get('to') in ({route} | groups) and reference(r)})
    proofs = {}
    for start in range(0, len(refs), 128):
        status, result = call({'action': 'delivery-status-batch', 'references': refs[start:start+128]}, timeout=3)
        if status != 200 or not result.get('ok'): raise ValueError('Signal receipt read unavailable; eligibility is unknown')
        proofs.update(result.get('results', {}))
    # The host can accept a request before its client records a trajectory
    # step (timeout/crash). Import receipt metadata for those missing steps too.
    now = dt.datetime.now(UTC).timestamp()
    indexed = {reference(r) for r in rows if r.get('from') == os.environ.get('IDENTITY_NAME', 'custos')}
    destinations = data.get('destinations') or data.get('contacts') or []
    for contact in destinations:
        if not isinstance(contact, dict) or not contact.get('target'): continue
        room = route_for(contact['target'])
        if room not in ({route} | groups): continue
        status, result = call({'action':'signal-contact-outbox','target':contact['target'],'since':max(0,now-max(hours,12)*3600)},timeout=3)
        if status != 200 or not result.get('ok'): raise ValueError('host contact outbox unavailable; eligibility is unknown')
        for outgoing in result.get('outgoing', []):
            ref = outgoing['reference']; proofs[ref] = outgoing
            if ref in indexed: continue
            kind, key = ref.split(':',1)
            row = {'from':os.environ.get('IDENTITY_NAME','custos'),'to':room,'ts':iso(outgoing['created']),
                   'step_id':key, 'source':'host-receipt'}
            if kind == 'action': row.update(request_id=key, delivered_by='custos-actions')
            rows.append(row); indexed.add(ref)
    return evaluate(rows, target, route, hours, cross, lambda ref: proofs.get(ref, {'phase': 'unknown'}), now, os.environ.get('IDENTITY_NAME', 'custos'))
