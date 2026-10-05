"""Kitchen intent and conversation guards shared by responder, CLI and bridge.

The responder supplies semantic interpretation in its existing call. Deterministic
fallbacks recognize explicit requests, never manufacture a cart-add from food nouns.
"""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import time

FOOD = re.compile(r'\b(cart|grocer(?:y|ies)|meal ?plan|meals?|menu|dinners?|recipes?|pantry|staples?|whole foods|peanut butter|tahini|yogurt|milk|bananas?|apples?|pickup)\b', re.I)
BUILD = re.compile(r'\b(build|implement|coding|deploy|repo|refactor|redesign|research|audit|investigate|feature|dashboard|harness)\b', re.I)
REMINDER = re.compile(r'\b(remind|reminder|alarm|nudge|ping me|ping us)\b', re.I)
STOP = re.compile(r"\b(we['’]?re all set|we are all set|leave (?:it|the rest) (?:be|to us)|take no action|skip (?:it|this week)|not this week|stop (?:reminding|nagging)|no more (?:pings|reminders))\b", re.I)
CONTEXT = re.compile(r"\b(?:we|I|[A-Z][a-z]+ and I) (?:like|love|usually|often) to (?:make|eat|cook)|\b(?:just|only) (?:giving|sharing) context\b", re.I)
REQUEST = re.compile(r"\b(?:can you|could you|would you)\b|(?:^|[\n.!?]\s*)(?:(?:hi|thanks|thank you)[!, ]*\s*)?(?:please\s+)?(?:add|remove|drop|swap|put|grab|include|keep|move|change|let['’]s|we need|I need|I['’]d like|I want)\b", re.I)
INVENTORY = re.compile(r"\b(?:we|I) (?:already )?have\b|\b(?:we|I) (?:don['’]t|do not) need\b", re.I)
KINDS = {'request', 'question', 'preference', 'inventory', 'context', 'stop'}
ACTIONS = {'add','remove','swap','recipe','plan','pickup','inventory','preference','query','stop','context'}


def body_text(content):
    return content.split('Message:\n', 1)[-1].split('\nParticipation:', 1)[0]


def eligible_text(incoming):
    body = body_text(incoming.get('content', ''))
    routing = incoming.get('signal_routing')
    if not routing: return body
    allowed = set(routing.get('eligible', [])); selected = []; keep = False
    for line in body.splitlines():
        try: meta = json.loads(line)
        except ValueError: meta = None
        if isinstance(meta, dict) and 'category' in meta and 'id' in meta:
            keep = meta['id'] in allowed
        elif keep and not line.startswith('Reply-eligible message IDs:'): selected.append(line)
    return '\n'.join(selected)


def fallback(body):
    clean = re.sub(r'^\{[^\n]+\}\s*', '', body, flags=re.M).strip()
    if BUILD.search(clean): return None
    if STOP.search(clean): return {'kind': 'stop', 'action': 'stop', 'evidence': STOP.search(clean)[0]}
    if REMINDER.search(clean) or BUILD.search(clean): return None
    if CONTEXT.search(clean) and not REQUEST.search(clean):
        return {'kind': 'context', 'action': 'context', 'evidence': CONTEXT.search(clean)[0]}
    if not FOOD.search(clean) and not re.search(r'https?://|\b(?:Thursday|Monday|Tuesday|Wednesday|Friday|Saturday|Sunday)\b', clean, re.I): return None
    if re.search(r"\b(?:what(?:['’]s| is)|which)\b.*\b(?:meal|dinner|recipe)\b", clean, re.I): return {'kind': 'question', 'action': 'query', 'evidence': clean[:400]}
    if INVENTORY.search(clean): return {'kind': 'inventory', 'action': 'inventory', 'evidence': INVENTORY.search(clean)[0]}
    match = REQUEST.search(clean)
    if match:
        verb = match[0].lower()
        action = ('remove' if re.search(r'\b(remove|drop)\b|take.{0,30}off', clean, re.I) else 'swap' if re.search(r'\b(swap|replace)\b', clean, re.I) else
                  'pickup' if 'pickup' in clean.lower() else 'recipe' if re.search('https?://|recipe|menu|dinner', clean, re.I) else 'add')
        return {'kind': 'request', 'action': action, 'evidence': match[0].strip()}
    return None


def interpret(incoming, supplied=None):
    if incoming.get('authority') != 'operator': return None
    body = eligible_text(incoming); detected = fallback(body)
    if detected and detected['kind'] in ('context', 'stop'):
        detected['source_ids'] = incoming.get('signal_routing', {}).get('eligible', [incoming.get('request_id')])
        return detected
    if REMINDER.search(body) or BUILD.search(body): return None
    if isinstance(supplied, dict):
        kind, action = supplied.get('kind'), supplied.get('action')
        evidence = supplied.get('evidence')
        if kind not in KINDS or action not in ACTIONS or not isinstance(evidence, str) or not evidence.strip() or evidence not in body:
            raise ValueError('kitchen intent needs a valid kind/action and an exact eligible source quote')
        if not isinstance(supplied.get('items', []), list): raise ValueError('kitchen items must be a list')
        pairs = {'request': {'add','remove','swap','recipe','plan','pickup'}, 'question': {'query'}, 'preference': {'preference'}, 'inventory': {'inventory'}, 'context': {'context'}, 'stop': {'stop'}}
        if action not in pairs[kind]: raise ValueError('kitchen kind/action mismatch')
        ids = incoming.get('signal_routing', {}).get('eligible', [incoming.get('request_id')])
        return {'kind': kind, 'action': action, 'evidence': evidence[:800],
                'items': [str(x)[:200] for x in supplied.get('items', [])[:20]],
                'date': supplied.get('date'), 'source_ids': ids}
    if detected:
        detected.setdefault('items', []); detected.setdefault('date', None)
        detected['source_ids'] = incoming.get('signal_routing', {}).get('eligible', [incoming.get('request_id')])
    return detected


def hint(intent):
    if intent['kind'] == 'question':
        return 'NOW: read `mealplan meals` for the requested date and answer with the recorded title/link. Do not alter any plan or cart.'
    if intent['kind'] == 'preference':
        return 'NOW: read custos-mealplan and household topic e93fc9a3; merge only the stated lasting preference, update kitchen settings if applicable and verify. Keep person summaries unchanged.'
    return ('NOW: read `mealplan context`, load custos-mealplan, import a requested recipe URL with `mealplan recipe import URL` when needed, and apply only the source-backed '
            + intent['action'] + ' change using revision/cursor and a stable operation ID. '
            'Use mealplan change then reconcile/calendar as needed; preserve household edits. '
            'Return one verified result to the source message, then complete the task. Checkout is never owed work. '
            'Source interpretation: ' + json.dumps(intent, ensure_ascii=False))


def household_context(db, policy):
    rows = []
    for row in db.execute("SELECT id,payload FROM inbox ORDER BY json_extract(payload,'$.timestamp'), id"):
        item = json.loads(row['payload'])
        person = policy.get('people', {}).get(item.get('sender_aci'), {})
        if person.get('authority') != 'operator' or person.get('label') not in {'Hal', 'Dani'}: continue
        if item.get('reaction'): continue
        rows.append({'id': row['id'], 'at': item.get('timestamp'), 'speaker': person['label'],
                     'conversation': item.get('conversation'), 'body': item.get('body', '')})
    cursor = hashlib.sha256(json.dumps(rows, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return {'cursor': cursor, 'messages': rows[-20:], 'automatic_followups': False, 'purchase_status': 'unknown'}


def family_messages(identity=None):
    # Host intake includes messages still inside the existing burst-batch window.
    # An unavailable broker fails closed rather than accepting an unchecked cursor.
    import http.client
    connection = http.client.HTTPConnection('192.168.86.44', 18082, timeout=20)
    try:
        connection.request('POST', '/v1/actions', body=json.dumps({'action': 'kitchen-context'}), headers={'Content-Type': 'application/json'})
        response = connection.getresponse(); value = json.loads(response.read(262145))
        if response.status != 200 or not re.fullmatch('[a-f0-9]{64}', value.get('cursor', '')): raise ValueError('household intake is unavailable; no mutation allowed')
        return value['cursor'], value['messages']
    finally: connection.close()


@contextlib.contextmanager
def mutation_guard(cursor, cycle, task):
    current, _ = family_messages()
    if current != cursor: raise ValueError('new household message arrived; read context and rebase before changing anything')
    path = Path(os.environ['IDENTITY_DIR']) / '.state' / 'kitchen-write.lock'
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as handle:
        try: fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise ValueError('another kitchen mutation is active; wait for its result, then read context')
        if family_messages()[0] != cursor: raise ValueError('household context changed while acquiring the kitchen lock')
        # The lease names an existing native goal; it is not a second task store.
        from custos_memory import Store
        record = Store().find(task)[4]
        if not record or record['status'] != 'active': raise ValueError('an active native task is required')
        lease_path = path.with_name('kitchen-lease.json')
        try: lease = json.loads(lease_path.read_text())
        except FileNotFoundError: lease = {}
        if (lease.get('cycle') == cycle and lease.get('task') != task and lease.get('cursor') == cursor
                and lease.get('until', 0) > time.time()):
            raise ValueError('another native kitchen task owns this revision; resume that task or wait for lease expiry')
        atomic_json(lease_path, {'cycle': cycle, 'task': task, 'cursor': cursor, 'until': time.time() + 300})
        yield


def atomic_json(path, value):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.tmp')
    with tmp.open('w') as f:
        json.dump(value, f, ensure_ascii=False, indent=2); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, path)


def household_origin(origin):
    return origin.get('authority') == 'operator' and origin.get('request_id', '').startswith('signal:') and origin.get('sender', '').startswith('signal')


def record_boundary(store, origin):
    if not household_origin(origin): return
    intent = interpret(origin)
    if not intent or intent['kind'] != 'stop': return
    # Called under the native store lock; person-summary replacement cannot erase it.
    path = store.state_dir() / 'kitchen-consent.json'
    atomic_json(path, {'version': 1, 'automatic_followups': False, 'purchase_status': 'unknown',
                      'source_id': origin['request_id'], 'evidence': intent['evidence'], 'recorded_at': time.time()})


def close_superseded(store, items):
    stops = [r for *_, r in items if r and household_origin(r['origin'])
             and (fallback(eligible_text(r['origin'])) or {}).get('kind') == 'stop']
    if not stops: return
    latest = max(stops, key=lambda r: r['received_at'])
    for item in items:
        record = item[4]
        if not record or record['status'] != 'active' or record['received_at'] >= latest['received_at']: continue
        goal_text = json.dumps(record.get('goal', {}))
        if not FOOD.search(goal_text): continue
        if record['origin'].get('authority') == 'operator' and REMINDER.search(eligible_text(record['origin'])): continue
        if BUILD.search(eligible_text(record['origin'])): continue
        resolution = {'disposition': 'completed', 'evidence': 'Kitchen assistance closed by ' + latest['origin']['request_id'] + '; no purchase asserted.'}
        record['status'] = 'completed'; record['resolution'] = resolution
        record['events'].append({'at': latest['received_at'], 'resolution': resolution})
        record.pop('waiting', None); record.pop('not_before', None)
        store.save(item, record)


def delivery_block(db, policy, conversation, message, request_id=None, created=0, kind='completion'):
    """Send-time check over host-verified intake; no second goals store or LLM."""
    rows = db.execute("SELECT id,payload FROM inbox ORDER BY json_extract(payload,'$.timestamp') DESC").fetchall()
    source = None; latest_stop = 0; kitchen_source = False
    for row in rows:
        item = json.loads(row['payload']); text = item.get('body', item.get('text', ''))
        # Only host-allowlisted operators can set a household boundary.
        person = policy.get('people', {}).get(item.get('sender_aci'), {})
        if person.get('authority') != 'operator' or person.get('label') not in {'Hal', 'Dani'}: continue
        if row['id'] == request_id and item.get('conversation') == conversation: source = item; kitchen_source = bool(FOOD.search(text))
        if STOP.search(text): latest_stop = max(latest_stop, item.get('timestamp', 0) / 1000)
    if not (kitchen_source or FOOD.search(message or '')): return None
    # A real explicitly requested timer has its own durable record and receipt.
    if source and REMINDER.search(source.get('body', source.get('text', ''))) and not STOP.search(source.get('body', '')): return None
    if not source: return 'automatic kitchen follow-ups are disabled; correlate a real household request'
    if re.search(r'last call|before (?:the )?order locks|place (?:it|the order).*mark.*done|(?:reminder|nudge).*checkout', message or '', re.I) or (not source and re.search(r'place (?:it|the order)|check ?out|pickup.*today|pick.*window', message or '', re.I)):
        return 'unsolicited kitchen checkout reminders are disabled; cart assistance ends independently of purchase'
    if latest_stop and (not source or source.get('received', source.get('timestamp', 0)) / 1000 < latest_stop):
        # A short acknowledgment of the closure itself is still permitted.
        if source and STOP.search(source.get('body', source.get('text', ''))) and len(message) < 160: return None
        return 'household closed kitchen follow-ups; only a new request can reopen them'
    return None
