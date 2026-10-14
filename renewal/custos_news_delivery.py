"""Routine news batching is independent of the minimum conversation guard."""
import datetime as dt
import json
import os
from pathlib import Path


def check_batch(payload, target, call, store=None, now=None):
    from custos_memory import Store, submitted
    from custos_contact_guard import timestamp, route_for
    store = store or Store()
    # Corrections already owed take precedence over adding another optional digest.
    for item in store.files():
        rec = item[4]
        if rec and rec['status'] == 'active' and rec['origin']['request_id'].startswith('correction:') and rec['origin']['sender'] in {route_for(target), 'operator:ai-news-review'}:
            return {'ok': False, 'reason': 'pending-correction', 'meaning': 'Resolve the pending correction before optional news; do other work meanwhile.',
                    'wait': {'dependency_goal': item[3]['id']}}
    urgent = payload.get('news_urgent_reason')
    if urgent:
        if not isinstance(urgent, str) or not 30 <= len(urgent) <= 1000:
            raise ValueError('urgent news needs a concrete time-sensitive reason, 30..1000 characters')
        return {'ok': True, 'reason': 'time-sensitive-exception'}
    policy = json.loads((Path(os.environ['IDENTITY_DIR']) / 'social-policy.json').read_text())
    hours = policy.get('news_batch_hours', 6)
    if type(hours) is not int or hours < 1: raise ValueError('invalid news_batch_hours')
    current = now if now is not None else dt.datetime.now(dt.timezone.utc).timestamp()
    code, data = call({'action': 'signal-contact-outbox', 'target': target, 'since': max(0, current-hours*3600)}, timeout=3)
    if code != 200 or not data.get('ok'): raise ValueError('news receipt history unavailable; batching eligibility unknown')
    times = [timestamp(row['receipt']['timestamp']) for row in data.get('outgoing', [])
             if row.get('reference', '').startswith('action:ainews-') and submitted(row)]
    deadline = max(times, default=0) + hours*3600
    if times and deadline > current:
        return {'ok': False, 'reason': 'batch-window', 'meaning': 'Routine news is grouped less often than the contact cooldown. Reassess usefulness once at the batch boundary; it is not an automatic send appointment.',
                'wait': {'check_at': dt.datetime.fromtimestamp(deadline, dt.timezone.utc).isoformat()}}
    return {'ok': True, 'reason': 'batch-eligible', 'meaning': 'Batch window permits consideration; send only useful, corrected, nonduplicate items.'}
