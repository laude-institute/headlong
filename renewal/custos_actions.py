#!/usr/bin/env python3
"""Host-owned proactive Signal queue and fixed Automata deployment channel.

Only LXC122 is admitted. No caller-controlled command, container, path or socket.
Signal sending stays in its single existing worker; deployments run serially.
"""
import custos_kitchen as kitchen
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import tempfile
import threading
import time
import selectors
from custos_signal import load_policy, encoded, MAX_TEXT, lane_status
import custos_attachments as attachments

STATE = '/var/lib/custos-actions/actions.sqlite'
POLICY = '/etc/custos-signal/policy.json'
SPOOL = '/var/lib/custos-signal-bridge/spool.sqlite'  # the bridge's inbox, read here for inline asks
ASK_DAILY, ASK_SPACING, ASK_WAIT_MAX, ASK_ANNOTATE = 8, 60, 900, 1800  # Jack and Kim approved ~8/day (2026-09-10)
CHECKOUT = '/opt/custos/work/repos/collettiquette/automata'
MAX_BODY = 32768
UPLOAD_SLOT = threading.BoundedSemaphore(1)  # keep 8 MiB uploads inside the 256 MiB service budget


class Connection(sqlite3.Connection):
    def __exit__(self, *args):
        try:
            return super().__exit__(*args)
        finally:
            self.close()


def connect(path=STATE):
    db = sqlite3.connect(path, timeout=15, factory=Connection)
    db.row_factory = sqlite3.Row
    db.execute('PRAGMA journal_mode=WAL')
    db.execute('PRAGMA synchronous=FULL')
    db.execute('CREATE TABLE IF NOT EXISTS actions (id TEXT PRIMARY KEY, payload TEXT NOT NULL, '
               "phase TEXT NOT NULL DEFAULT 'queued', receipt TEXT, created REAL NOT NULL)")
    # An inline ask holds one DM conversation: the bridge does not deliver its replies as wakes
    # while the hold is live; the asking step reads them through signal-await instead.
    db.execute('CREATE TABLE IF NOT EXISTS holds (conversation TEXT PRIMARY KEY, request_id TEXT NOT NULL, '
               'created REAL NOT NULL, expires REAL NOT NULL, released REAL)')
    db.execute('CREATE TABLE IF NOT EXISTS attachments (request_id TEXT PRIMARY KEY, files TEXT NOT NULL, size INTEGER NOT NULL)')
    return db


def active_hold(db, conversation, now=None):
    row = db.execute('SELECT * FROM holds WHERE conversation=?', (conversation,)).fetchone()
    if row and row['released'] is None and row['expires'] > (now or time.time()):
        return row
    return None


def recent_ask(db, conversation, now=None):
    """An ask whose hold ended (expired, not released) within ASK_ANNOTATE: a late answer is probably its."""
    row = db.execute('SELECT * FROM holds WHERE conversation=?', (conversation,)).fetchone()
    now = now or time.time()
    if row and row['released'] is None and row['expires'] <= now < row['expires'] + ASK_ANNOTATE:
        return row['request_id']
    return None


def destinations(policy):
    return ([{'target': 'dm:' + who, 'label': p['label'], 'kind': 'dm'}
             for who, p in policy['people'].items()] +
            [{'target': 'group:' + g, 'label': policy.get('group_labels', {}).get(g, 'Group'), 'kind': 'group'}
             for g in policy['groups']])


def resolve(target, policy):
    if not isinstance(target, str):
        raise ValueError('target must be a current contact label or target from signal-contacts')
    matches = [d for d in destinations(policy)
               if target == d['target'] or target.casefold() == d['label'].casefold()]
    if len(matches) != 1:
        raise ValueError('target is not uniquely allowlisted; use signal-contacts')
    return matches[0]['target']


def validate(payload, policy):
    if not isinstance(payload, dict):
        raise ValueError('object required')
    action = payload.get('action')
    fields = {'signal-send': {'target', 'message'}, 'signal-ask': {'target', 'message', 'wait_seconds'},
              'automata-deploy': {'commit', 'goal_id'}, 'automata-rollback': {'goal_id'}}
    optional = {'attachments', 'reply_to', 'delivery_kind', 'correction_of'} if action == 'signal-send' else set()
    if (action not in fields or not fields[action] | {'action', 'request_id'} <= set(payload) or
            set(payload) - (fields[action] | {'action', 'request_id'} | optional)):
        raise ValueError('invalid action fields')
    if not isinstance(payload['request_id'], str) or not re.fullmatch(r'[A-Za-z0-9:._-]{1,128}', payload['request_id']):
        raise ValueError('stable request_id required')
    p = dict(payload)
    if action in ('signal-send', 'signal-ask'):
        p['target'] = resolve(p['target'], policy)
        if 'attachments' in p:
            p['attachments'] = attachments.validate(p['attachments'])
        if (not isinstance(p['message'], str) or len(p['message'].encode()) > MAX_TEXT or
                (not p['message'].strip() and not p.get('attachments'))):
            raise ValueError('message needs text or attachments; caption max 12000 UTF-8 bytes')
        if 'reply_to' in p and (not isinstance(p['reply_to'], str) or
                                not re.fullmatch(r'[A-Za-z0-9:._-]{1,128}', p['reply_to'])):
            raise ValueError('reply_to must be an inbound Signal request ID')
        if not isinstance(p.get('delivery_kind', 'completion'), str) or p.get('delivery_kind', 'completion') not in {'acknowledgment', 'completion', 'correction'}:
            raise ValueError('invalid delivery_kind')
        if (p.get('delivery_kind') == 'correction') != bool(p.get('correction_of')):
            raise ValueError('correction needs delivery_kind and correction_of')
        if p.get('correction_of') and (not isinstance(p['correction_of'], str) or not re.fullmatch(r'(?:outbox|action):[A-Za-z0-9:._-]{1,128}', p['correction_of'])):
            raise ValueError('correction requires a valid original receipt reference')
        if action == 'signal-ask':
            if not p['target'].startswith('dm:'):
                raise ValueError('an inline ask goes to one person or bot by DM, never a group')
            if type(p['wait_seconds']) is not int or not 30 <= p['wait_seconds'] <= ASK_WAIT_MAX:
                raise ValueError('wait_seconds must be 30..%d' % ASK_WAIT_MAX)
    else:
        if not isinstance(p['goal_id'], str) or not re.fullmatch(r'[0-9a-f]{8}', p['goal_id']):
            raise ValueError('native goal_id required')
        if action == 'automata-deploy' and (not isinstance(p['commit'], str) or not re.fullmatch(r'[0-9a-f]{40}', p['commit'])):
            raise ValueError('full published Git commit required')
    return p


def receipt(row):
    return {'ok': True, 'request_id': row['id'], 'phase': row['phase'],
            'receipt': json.loads(row['receipt']) if row['receipt'] else None}


class Channel:
    def __init__(self, state=STATE, policy=POLICY, spool=SPOOL):
        self.state, self.policy, self.spool = state, policy, spool
        connect(state).close()

    def ask_lookup(self, db, payload):
        if not isinstance(payload.get('request_id'), str):
            raise ValueError('request_id required')
        row = db.execute('SELECT * FROM actions WHERE id=?', (payload['request_id'],)).fetchone()
        if not row or json.loads(row['payload']).get('action') != 'signal-ask':
            raise ValueError('unknown ask')
        hold = db.execute('SELECT * FROM holds WHERE request_id=?', (row['id'],)).fetchone()
        return row, hold

    def await_(self, payload):
        """Replies that arrived in the held conversation since the ask, taken out of the bridge's
        delivery path (phase consumed) so they never also become a wake."""
        with connect(self.state) as db:
            row, hold = self.ask_lookup(db, payload)
        if not hold:
            raise ValueError('ask has no hold record')
        now = time.time(); replies = []
        spool = sqlite3.connect(self.spool, timeout=15); spool.row_factory = sqlite3.Row
        try:
            with spool:
                for r in spool.execute("SELECT id,payload,phase FROM inbox WHERE json_extract(payload,'$.conversation')=? "
                                       "AND json_extract(payload,'$.timestamp')>? AND phase IN ('pending','consumed') "
                                       "ORDER BY json_extract(payload,'$.timestamp')", (hold['conversation'], int(row['created'] * 1000))):
                    item = json.loads(r['payload'])
                    if item.get('reaction') or item['sender_aci'] != hold['conversation'][3:]:
                        continue
                    if r['phase'] == 'pending':
                        spool.execute("UPDATE inbox SET phase='consumed',receipt=? WHERE id=? AND phase='pending'",
                                      (encoded({'consumed_by': row['id']}), r['id']))
                    replies.append({'at': item['timestamp'], 'label': item['label'], 'body': item['body']})
        finally:
            spool.close()
        return {'ok': True, 'request_id': row['id'], 'phase': row['phase'], 'replies': replies,
                'hold_active': hold['released'] is None and hold['expires'] > now, 'hold_expires': hold['expires']}

    def release(self, payload):
        with connect(self.state) as db:
            row, hold = self.ask_lookup(db, payload)
            db.execute('UPDATE holds SET released=? WHERE request_id=? AND released IS NULL', (time.time(), row['id']))
        return {'ok': True, 'request_id': row['id'], 'released': True}

    def handle(self, payload):
        if not isinstance(payload, dict):
            raise ValueError('object required')
        if payload == {'action': 'kitchen-context'}:
            with sqlite3.connect('file:' + str(self.spool) + '?mode=ro', uri=True) as db:
                db.row_factory = sqlite3.Row
                return kitchen.household_context(db, load_policy(self.policy))
        if payload == {'action': 'signal-contacts'}:
            return {'ok': True, 'contacts': destinations(load_policy(self.policy))}
        if payload.get('action') == 'signal-lane-status' and set(payload) == {'action', 'target'}:
            policy = load_policy(self.policy)
            target = resolve(payload['target'], policy)
            return {'ok': True, 'target': target, **lane_status(self.spool, policy, self.state, target)}
        if payload == {'action': 'signal-asks'}:
            with connect(self.state) as db:
                rows = db.execute("SELECT a.id,a.phase,a.created,h.expires,h.released FROM actions a "
                                  "LEFT JOIN holds h ON h.request_id=a.id "
                                  "WHERE json_extract(a.payload,'$.action')='signal-ask' "
                                  "ORDER BY a.created DESC LIMIT 50").fetchall()
            return {'ok': True, 'asks': [dict(row) for row in rows]}
        if payload.get('action') == 'signal-await' and set(payload) == {'action', 'request_id'}:
            return self.await_(payload)
        if payload.get('action') == 'signal-release' and set(payload) == {'action', 'request_id'}:
            return self.release(payload)
        if payload.get('action') == 'status' and set(payload) == {'action', 'request_id'}:
            if not isinstance(payload['request_id'], str): raise ValueError('request_id required')
            with connect(self.state) as db:
                row = db.execute('SELECT * FROM actions WHERE id=?', (payload['request_id'],)).fetchone()
            return receipt(row) if row else {'ok': False, 'error': 'unknown_request'}
        if payload.get('action') == 'delivery-status-batch' and set(payload) == {'action', 'references'}:
            refs = payload['references']
            if not isinstance(refs, list) or not 1 <= len(refs) <= 128 or any(
                    not isinstance(ref, str) or not re.fullmatch(r'(?:outbox|action):[A-Za-z0-9:._-]{1,128}', ref) for ref in refs):
                raise ValueError('one to 128 valid delivery references required')
            results = {}
            for ref in refs:
                result = self.handle({'action': 'delivery-status', 'reference': ref})
                proof = result.get('receipt') or {}
                results[ref] = {'phase': result['phase'], 'record_found': result['ok'], 'receipt': {
                    'timestamp': proof.get('timestamp'), 'converted_to_reaction': proof.get('converted_to_reaction'),
                    'results': [{'type': r.get('type') if isinstance(r, dict) else 'INVALID'} for r in (proof.get('results') or [])]} if isinstance(proof, dict) else None}
            return {'ok': True, 'results': results}
        if payload.get('action') == 'delivery-status' and set(payload) == {'action', 'reference'}:
            reference = payload['reference']
            if not isinstance(reference, str) or not re.fullmatch(r'(?:outbox|action):[A-Za-z0-9:._-]{1,128}', reference):
                raise ValueError('invalid delivery reference')
            kind, identifier = reference.split(':', 1)
            path = self.spool if kind == 'outbox' else self.state
            # Receipt reads never create a DB, change its journal mode, or reserve a send.
            db = sqlite3.connect('file:' + str(path) + '?mode=ro', uri=True)
            try:
                db.row_factory = sqlite3.Row
                table = 'outbox' if kind == 'outbox' else 'actions'
                row = db.execute('SELECT phase,receipt FROM ' + table + ' WHERE id=?', (identifier,)).fetchone()
            finally:
                db.close()
            result = {'ok': bool(row), 'reference': reference, 'phase': row['phase'] if row else 'unknown',
                      'receipt': json.loads(row['receipt']) if row and row['receipt'] else None}
            return result
        if payload == {'action': 'automata-status'}:
            return {'ok': True, 'automata': json.loads(run_bounded(
                ['/usr/sbin/pct','exec','126','--','/usr/bin/python3',
                 '/usr/local/libexec/custos-automata-deploy.py','status'], timeout=25).decode())}
        # Resolve labels once; store the fixed routing target, not a mutable alias.
        p = validate(payload, load_policy(self.policy))
        files = p.get('attachments')
        if files:
            p['attachments'] = attachments.metadata(files)
        with connect(self.state) as db:
            db.execute('BEGIN IMMEDIATE')
            old = db.execute('SELECT * FROM actions WHERE id=?', (p['request_id'],)).fetchone()
            if old:
                if old['payload'] != encoded(p): raise ValueError('request_id belongs to different content')
                return receipt(old)
            if p['action'] in ('signal-send', 'signal-ask'):
                lane = lane_status(self.spool, load_policy(self.policy), self.state, p['target'], p.get('reply_to'))
                if lane['blocked']:
                    return {'ok': False, 'error': 'lane_blocked', 'request_id': p['request_id'], **lane}
            if files:
                size = sum(f['size'] for f in files)
                pending = db.execute('SELECT COALESCE(SUM(size),0) FROM attachments').fetchone()[0]
                if pending + size > attachments.MAX_QUEUED_BYTES:
                    raise ValueError('attachment queue full; reconcile pending/uncertain sends first')
                db.execute('INSERT INTO attachments VALUES(?,?,?)', (p['request_id'], encoded(files), size))
            now = time.time()
            if p['action'] == 'signal-ask':
                open_hold = active_hold(db, p['target'], now)
                if open_hold:
                    raise ValueError('an ask is already open in that conversation: ' + open_hold['request_id'])
                day = db.execute("SELECT COUNT(*) FROM actions WHERE json_extract(payload,'$.action')='signal-ask' AND created>?",
                                 (now - 86400,)).fetchone()[0]
                if day >= ASK_DAILY:
                    raise ValueError('daily ask budget (%d) is used up; try tomorrow' % ASK_DAILY)
                last = db.execute("SELECT MAX(created) FROM actions WHERE json_extract(payload,'$.action')='signal-ask'").fetchone()[0]
                if last and now - last < ASK_SPACING:
                    raise ValueError('asks are at least %d s apart' % ASK_SPACING)
                db.execute('INSERT OR REPLACE INTO holds(conversation,request_id,created,expires,released) VALUES(?,?,?,?,NULL)',
                           (p['target'], p['request_id'], now, now + p['wait_seconds']))
            db.execute('INSERT INTO actions(id,payload,created) VALUES(?,?,?)',
                       (p['request_id'], encoded(p), now))
            row = db.execute('SELECT * FROM actions WHERE id=?', (p['request_id'],)).fetchone()
        result = receipt(row)
        if p['action'] == 'signal-ask':
            result.update({'conversation': p['target'], 'hold_expires': now + p['wait_seconds']})
        return result


def run_bounded(args, timeout=90, maximum=1048576):
    """Bound host subprocess output/time; never execute shell or guest code here."""
    proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
    parts, size = [], 0
    deadline = time.monotonic() + timeout
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(proc.stdout, selectors.EVENT_READ)
            while selector.get_map():
                if time.monotonic() >= deadline: raise TimeoutError('command timeout')
                for key, _ in selector.select(min(1, max(0, deadline-time.monotonic()))):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj); continue
                    size += len(chunk)
                    if size > maximum: raise ValueError('command output limit')
                    parts.append(chunk)
        if proc.wait(timeout=max(0.1, deadline-time.monotonic())):
            raise RuntimeError('fixed command failed')
        return b''.join(parts)
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL); proc.wait()
        proc.stdout.close()


def deploy(payload):
    prefix = ['/usr/sbin/pct','exec','126','--','/usr/bin/python3','/usr/local/libexec/custos-automata-deploy.py']
    if payload['action'] == 'automata-rollback':
        return json.loads(run_bounded(prefix+['rollback'], timeout=120))
    commit = payload['commit']
    git = ['/usr/sbin/pct','exec','122','--','/usr/bin/git','-C',CHECKOUT]
    # Fixed GitHub source. A published branch must contain the requested commit.
    run_bounded(git+['fetch','--prune','https://github.com/collettiquette/automata.git',
                     '+refs/heads/*:refs/remotes/custos-deploy/*'])
    branches = run_bounded(git+['for-each-ref','--contains',commit,'--format=%(refname)',
                               'refs/remotes/custos-deploy/'])
    if not branches.strip(): raise ValueError('commit is not on a published Automata branch')
    archive = run_bounded(git+['archive','--format=tar',commit+':particle-life'], maximum=32*1024*1024)
    # Archive bytes are opaque on the host; extraction/code execution is in 126.
    with tempfile.TemporaryDirectory(prefix='automata-', dir='/var/lib/custos-actions') as tmp:
        path = Path(tmp)/'source.tar'; path.write_bytes(archive)
        run_bounded(['/usr/sbin/pct','push','126',str(path),'/var/lib/custos-automata-incoming/source.tar'])
        return json.loads(run_bounded(prefix+['deploy',commit,hashlib.sha256(archive).hexdigest()], timeout=240))


def worker(state=STATE):
    from custos_signal import paused
    with connect(state) as db:
        db.execute("UPDATE actions SET phase='uncertain' WHERE phase='running'")
    while True:
        try:
            if paused(): time.sleep(2); continue
            with connect(state) as db:
                db.execute('BEGIN IMMEDIATE')
                row = db.execute("SELECT * FROM actions WHERE phase='queued' AND "
                                 "json_extract(payload,'$.action') IN ('automata-deploy','automata-rollback') "
                                 'ORDER BY created LIMIT 1').fetchone()
                if row: db.execute("UPDATE actions SET phase='running' WHERE id=?", (row['id'],))
            if row:
                try:
                    result = deploy(json.loads(row['payload']))
                    phase = 'succeeded' if result.get('ok') else 'failed'
                except Exception as error:
                    # Could have switched before losing the response; never retry automatically.
                    result, phase = {'error': type(error).__name__, 'reconcile': 'Use automata-status before a new deployment'}, 'uncertain'
                with connect(state) as db:
                    db.execute('UPDATE actions SET phase=?,receipt=? WHERE id=?', (phase,encoded(result),row['id']))
        except Exception:
            print('custos-actions: deployment worker unavailable', flush=True)
        time.sleep(2)


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup(); self.connection.settimeout(10)
    def log_message(self, *args): pass
    def do_POST(self):
        code = 200
        upload_slot = False
        try:
            if self.client_address[0] != '192.168.86.52':
                code=403; raise ValueError('client not allowed')
            if self.path not in {'/v1/actions','/v1/harness'}:
                code=404; raise ValueError('unknown path')
            lengths=self.headers.get_all('Content-Length', [])
            maximum = attachments.MAX_WIRE if self.path == '/v1/actions' else MAX_BODY
            if (self.headers.get('Transfer-Encoding') or len(lengths)!=1 or
                not re.fullmatch(r'[0-9]{1,8}',lengths[0]) or not 0<int(lengths[0])<=maximum or
                self.headers.get_content_type()!='application/json'):
                raise ValueError('bounded JSON body required')
            if int(lengths[0]) > MAX_BODY:
                upload_slot = UPLOAD_SLOT.acquire(blocking=False)
                if not upload_slot:
                    code=503; raise ValueError('attachment upload busy; retry the exact request ID and files')
            raw=self.rfile.read(int(lengths[0]))
            if len(raw)!=int(lengths[0]): raise ValueError('incomplete body')
            if self.path=='/v1/harness':
                import socket
                with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as upstream:
                    upstream.settimeout(12);upstream.connect('/run/custos-harness.sock')
                    upstream.sendall(raw+b'\n')
                    with upstream.makefile('rb') as response:
                        line=response.readline(1024*1024+1)
                    if len(line)>1024*1024 or not line.endswith(b'\n'):raise ValueError('invalid supervisor response')
                    result=json.loads(line)
            else:
                payload = json.loads(raw)
                if len(raw) > MAX_BODY and (not isinstance(payload, dict) or payload.get('action') != 'signal-send'):
                    raise ValueError('large bodies are only allowed for signal-send attachments')
                result=self.server.channel.handle(payload)
        except (ValueError, UnicodeError, RecursionError) as error:
            code=400 if code==200 else code; result={'ok':False,'error':str(error)[:200]}
        except Exception:
            code=503; result={'ok':False,'error':'unavailable; reuse original request_id'}
        finally:
            if upload_slot:
                UPLOAD_SLOT.release()
        body=encoded(result).encode()
        try:
            self.send_response(code); self.send_header('Content-Type','application/json')
            self.send_header('Content-Length',str(len(body))); self.send_header('Connection','close')
            self.end_headers(); self.wfile.write(body)
        except OSError: pass
        self.close_connection=True


def main():
    os.umask(0o077)
    channel=Channel()
    threading.Thread(target=worker,daemon=True).start()
    with ThreadingHTTPServer(('192.168.86.44',18082),Handler) as server:
        server.channel=channel; server.serve_forever()

if __name__=='__main__': main()
