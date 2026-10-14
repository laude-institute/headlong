"""Scheduling metadata for existing self-authored native goals, never new asks.

The native file is authoritative. A content change invalidates a parked wait;
expiry is never extended here. Call mutations under Store.lock().
"""
import datetime as dt
import hashlib
import json
from pathlib import Path


def path(store): return store.state_dir() / 'own-goal-waits.json'


def read(store):
    p = path(store)
    return json.loads(p.read_text()) if p.exists() else {}


def write(store, rows):
    from custos_dream import write_json
    write_json(path(store), rows)


def active(item):
    return not item[4] and item[3].get('type') in {'todo', 'goal', 'intention', 'objective'} and not (
        item[3].get('until') and item[3]['until'] < dt.datetime.now(dt.timezone.utc).date().isoformat())


def get(store, item):
    row = read(store).get(item[3]['id'])
    if not row or not active(item) or row.get('sha256') != hashlib.sha256(item[0].read_bytes()).hexdigest(): return None
    return row


def park(store, item, wait):
    rows = read(store); key = item[3]['id']; old = get(store, item) or {}
    old.pop('contact_resolved', None)
    rows[key] = {**old, 'sha256': hashlib.sha256(item[0].read_bytes()).hexdigest(), 'waiting': wait,
                 'events': (old.get('events', []) + [{'waiting': wait}])[-40:]}
    write(store, rows)
    return {'goal_id': key, 'directed': False, 'waiting': wait}


def resume(store, item, evidence):
    rows = read(store); key = item[3]['id']; old = get(store, item)
    if not old or not old.get('waiting'): raise ValueError('own goal is not waiting')
    wait = old.pop('waiting')
    old['events'] = (old.get('events', []) + [{'resumed': evidence, 'previous_wait': wait}])[-40:]
    old['resumed_at'] = dt.datetime.now(dt.timezone.utc).isoformat()
    rows[key] = old; write(store, rows)


def note(store, item, text):
    rows = read(store); key = item[3]['id']; old = get(store, item) or {'sha256': hashlib.sha256(item[0].read_bytes()).hexdigest()}
    if old.get('notes') and old['notes'][-1]['text'] == text:
        return {'goal_id': key, 'notes': len(old['notes']), 'directed': False, 'unchanged': True}
    old['notes'] = (old.get('notes', []) + [{'at': dt.datetime.now(dt.timezone.utc).isoformat(), 'text': text}])[-40:]
    rows[key] = old; write(store, rows)
    return {'goal_id': key, 'notes': len(old['notes']), 'directed': False}


def pending_contact(store, target):
    """Older explicitly parked contact gets a decision before optional news."""
    pending = []
    for item in store.files():
        row = get(store, item)
        if not row: continue
        wait = row.get('waiting')
        # Resuming for consideration does not mean the contact was delivered.
        if not wait:
            wait = next((e['previous_wait'] for e in reversed(row.get('events', [])) if 'previous_wait' in e), None)
        if wait and wait.get('signal_target') == target and not row.get('contact_resolved'):
            pending.append({'goal_id': item[3]['id'], 'summary': item[2][:160], 'priority_since': item[3].get('created') or wait['since'], **wait})
    return min(pending, key=lambda r: r['priority_since']) if pending else None


def resolve_contact(store, item, evidence):
    rows = read(store); row = get(store, item)
    if row:
        row['contact_resolved'] = evidence; row.pop('waiting', None)
        rows[item[3]['id']] = row; write(store, rows)
