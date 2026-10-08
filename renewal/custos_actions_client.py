#!/usr/bin/env python3
"""Custos's proactive Signal and Automata commands. Writes read JSON on stdin.

custos-actions signal-contacts
custos-actions signal-send < {request_id,target,message}.json
custos-actions automata-status
custos-actions automata-deploy < {request_id,goal_id,commit}.json
custos-actions automata-rollback < {request_id,goal_id}.json
custos-actions status REQUEST_ID
(inline asks: see bin/ask-agent — signal-ask / signal-await / signal-release)
Queue acceptance is not delivery. Reuse the exact request ID/payload on timeout.

signal-send goes through the same conversation guard as `chat` (when the caller
sets CHAT_DOUBLE_TEXT_GUARD_HOURS / CHAT_SOCIAL_BLOCKED, as the social thinker
does) and records the accepted message as a `message` step in the root
trajectory, marked delivered_by=custos-actions so the bridge does not send it
twice. On 2026-09-09 a send that `chat` had refused went out through here
unrecorded.
"""
import argparse
import datetime as dt
import hashlib
import http.client
import json
import os
from pathlib import Path
import subprocess
import sys
import custos_attachments as attachments
from custos_memory import MemoryError as GoalMemoryError

HOST, PORT = '192.168.86.44', 18082


def call(payload, timeout=40):
    connection = http.client.HTTPConnection(HOST, PORT, timeout=timeout)
    try:
        connection.request('POST', '/v1/actions', body=json.dumps(payload).encode(), headers={'Content-Type': 'application/json'})
        response = connection.getresponse(); raw = response.read(1048577)
        if len(raw) > 1048576: raise ValueError('response limit')
        return response.status, json.loads(raw)
    finally:
        connection.close()


def explain_status(result):
    """Add scheduling semantics without upgrading the host's delivery evidence."""
    if not isinstance(result, dict) or 'phase' not in result:
        return result
    phase = result['phase']
    states = {
        'suppressed': (False, True, 'Terminal suppressed delivery. The intended text was not submitted and will not retry.',
                       'Inspect the original receipt and spent claim; use a verified correction when appropriate, never a new ID to bypass suppression.'),
        'pending': (True, False, 'Recorded in the native transport spool; submission is pending.', 'Wait for its receipt.'),
        'sending': (False, False, 'Transport attempt is in flight; outcome is not established.', 'Reconcile this reference; do not resend.'),
        'queued': (True, False, 'Host retained the action; queue acceptance is not delivery.',
                   'Wait for a receipt or relevant transport event; do useful other work.'),
        'running': (False, False, 'Action is in progress; acceptance is not established.',
                    'Reconcile this request ID; do not duplicate an in-flight action.'),
        'blocked': (False, True, 'Terminal blocked action. It is not queued and will not automatically retry.',
                    'The reason in receipt must be resolved and eligibility independently re-established. '
                    'A policy change or new eligible inbound event may justify reconsideration; this row stays blocked. '
                    'Do not poll unchanged state, invent a new ID to bypass the guard, or promise automatic delivery.'),
        'uncertain': (False, True, 'Acceptance is unknown; automatic retry risks a duplicate.',
                      'Reconcile the original request and transport receipt before any new send.'),
        'submitted': (False, True, 'Transport submission recorded; inspect receipt for timestamp and per-recipient SUCCESS. Not a read receipt.',
                      'No retry; retain the actual receipt as evidence.'),
        'succeeded': (False, True, 'Action reports success; inspect its receipt for the actual result.', 'No retry.'),
        'failed': (False, True, 'Action failed and is not queued.', 'Resolve the receipt error before reconsideration.'),
    }
    automatic, terminal, meaning, resume = states.get(phase, (False, False, 'Unknown phase; no delivery or retry claim is justified.', 'Inspect the original receipt.'))
    return {**result, 'delivery_state': {'automatic_retry': automatic, 'terminal': terminal,
                                       'meaning': meaning, 'resume_condition': resume}}


def resolve_target(target, contacts):
    """A `dm:`/`group:` target as is; otherwise a unique label from signal-contacts."""
    if not isinstance(target, str):
        raise ValueError('target must be a string')
    if target.startswith(('dm:', 'group:')):
        return target
    matches = [c for c in contacts if isinstance(c, dict) and str(c.get('label', '')).casefold() == target.casefold()]
    if len(matches) != 1:
        raise ValueError('target is not uniquely allowlisted; use signal-contacts')
    return matches[0]['target']


def route_for(target):
    """The trajectory routing key the bridge uses for this conversation."""
    return 'signal-' + hashlib.sha256(target.encode()).hexdigest()[:24]


def social_guard(route):
    """Explicit unsolicited intent: same-room + cross-room guard, own policy.

    Requested completions keep their original correlation/guard path. This flag
    never weakens delivery claims, membership checks, or host bot limits.
    """
    policy_path = Path(os.environ['IDENTITY_DIR']) / 'social-policy.json'
    policy = json.loads(policy_path.read_text())
    if policy.get('proactive', True) is False:
        raise ValueError('proactive social contact is disabled in social-policy.json')
    hours = policy.get('initiate_after_hours', 12)
    ceiling = policy.get('unsolicited_per_day', 0)
    if type(hours) is not int or hours < 0 or type(ceiling) is not int or ceiling < 0:
        raise ValueError('invalid social policy; inspect it before sending')
    previous = {k: os.environ.get(k) for k in ('CHAT_DOUBLE_TEXT_GUARD_HOURS', 'CHAT_GUARD_CROSS_ROOM')}
    try:
        os.environ['CHAT_DOUBLE_TEXT_GUARD_HOURS'] = str(hours)
        os.environ['CHAT_GUARD_CROSS_ROOM'] = '1'
        guard(route)
        if ceiling:
            root = os.environ.get('ROOT_TRAJ_ID') or os.environ.get('TRAJ_ID')
            subprocess.run(['chat', 'history', '--with', route, '-n', '1', '--json'], capture_output=True, text=True, timeout=30, check=True)
            lookup = subprocess.run(['traj', 'path', root or ''], capture_output=True, text=True, timeout=30, check=True)
            index = Path(lookup.stdout.strip()).parent / 'messages.jsonl'
            since = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=24)).isoformat()[:19]
            ids = set()
            if index.exists():
                with index.open() as stream:
                    for line in stream:
                        row = json.loads(line)
                        if row.get('social_intent') and row.get('from') == os.environ.get('IDENTITY_NAME', 'custos') and row.get('ts', '')[:19] >= since:
                            from custos_contact_guard import reference, UNSENT
                            from custos_memory import delivery_status
                            if delivery_status(reference(row) or '') .get('phase') not in UNSENT:
                                ids.add(row.get('request_id') or row.get('step_id'))
            if len(ids) >= ceiling:
                raise ValueError('unsolicited-message allowance reached; silence is available')
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


class GuardRefusal(ValueError):
    def __init__(self, decision):
        self.decision = decision
        super().__init__(decision.get('error', 'contact guard refused'))


def guard(route):
    """Use the same canonical conversation and receipts as chat guard."""
    if os.environ.get('CHAT_SOCIAL_BLOCKED'):
        raise ValueError(os.environ['CHAT_SOCIAL_BLOCKED'])
    from custos_contact_guard import check
    result = check(route)
    if not result['ok']: raise GuardRefusal(result)
    return result


def mind_guard(route):
    """Use the same current mind window when the observer checks a parked goal."""
    policy = json.loads((Path(os.environ['IDENTITY_DIR']) / 'social-policy.json').read_text())
    hours = policy.get('mind_double_text_hours', 2)
    if type(hours) is not int or hours < 0: raise ValueError('invalid mind double-text window')
    previous = {k: os.environ.get(k) for k in ('CHAT_DOUBLE_TEXT_GUARD_HOURS', 'CHAT_GUARD_CROSS_ROOM')}
    try:
        os.environ['CHAT_DOUBLE_TEXT_GUARD_HOURS'] = str(hours)
        os.environ['CHAT_GUARD_CROSS_ROOM'] = '0'
        guard(route)
    finally:
        for key, value in previous.items():
            if value is None: os.environ.pop(key, None)
            else: os.environ[key] = value


def park_cooldown(goal_id, payload, target, social, refusal):
    """Persist the exact unsent request and park only a known local cooldown."""
    decision = getattr(refusal, 'decision', {})
    if not goal_id or decision.get('reason') != 'cooldown': return None
    from custos_memory import Store
    store = Store()
    directory = Path(os.environ['IDENTITY_DIR']) / '.state' / 'staged-signal'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    raw = json.dumps(payload, sort_keys=True, ensure_ascii=False).encode()
    digest = hashlib.sha256(raw).hexdigest()
    path = directory / (hashlib.sha256(payload['request_id'].encode()).hexdigest() + '.json')
    try:
        with path.open('xb') as f: f.write(raw)
    except FileExistsError:
        if path.read_bytes() != raw: raise ValueError('staged request ID has a different payload; reconcile it before sending')
    store.note({'goal_id': goal_id, 'text': 'Not sent: local Signal cooldown. Exact request staged at ' + str(path)
        + '; request_id=' + payload['request_id'] + '; sha256=' + digest
        + '. Reuse this ID and payload after eligibility resumes; no host action was queued.'})
    return store.wait({'goal_id': goal_id, 'reason': 'Local Signal cooldown (' + ('social' if social else 'mind') + '); staged request ' + payload['request_id'],
                       'signal_target': target, 'check_at': decision['resume_at']})


def record(route, message, request_id, phase, files=None, reply_to=None, social=False, delivery_kind="completion", correction_of=None):
    """Append the accepted send to the root trajectory as a message step."""
    root = os.environ.get('ROOT_TRAJ_ID') or os.environ.get('TRAJ_ID')
    if not root:
        return
    step = {'type': 'message', 'from': os.environ.get('IDENTITY_NAME', 'custos'), 'to': route, 'content': message,
            'source': 'custos-actions', 'delivered_by': 'custos-actions', 'request_id': request_id, 'phase': phase}
    step['delivery_kind'] = delivery_kind
    if correction_of: step['correction_of'] = correction_of
    if social:
        step['social_intent'] = True
    if files:
        step['attachments'] = attachments.metadata(attachments.validate(files))
    if reply_to:
        step['reply_to'] = reply_to
    subprocess.run(['traj', 'append', root], input=json.dumps(step, ensure_ascii=False), text=True, capture_output=True, timeout=30)


def resolve_reply(step, route):
    if len(step) < 4:
        raise ValueError('reply-to needs a unique native step ID or prefix')
    matches = []
    for path in (Path(os.environ['IDENTITY_DIR']) / '.state' / 'transport').glob('*.json'):
        record = json.loads(path.read_text())
        if record['step_id'].startswith(step):
            matches.append(record)
    if len(matches) != 1 or matches[0]['phase'] != 'queued' or matches[0]['original']['sender'] != route:
        raise ValueError('reply-to must uniquely name a delivered message in this conversation')
    return matches[0]['original']['request_id'], matches[0]['step_id']


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('action', choices=['signal-guard', 'signal-lane-status', 'signal-contacts', 'signal-send', 'signal-ask', 'signal-await', 'signal-release', 'automata-status', 'automata-deploy', 'automata-rollback', 'status', 'delivery-status'])
    p.add_argument('request_id', nargs='?')
    p.add_argument('--attach', action='append', default=[], metavar='FILE', help='attach a guest file (repeat up to four; 8 MiB total)')
    p.add_argument('--reply-to', metavar='STEP', help='quote a delivered native Signal message (unique step ID/prefix)')
    p.add_argument('--goal', help='active deferred goal to park on a local Signal cooldown')
    p.add_argument('--social', action='store_true', help='unsolicited conversation: honor proactive policy and cross-room silence')
    p.add_argument('--delivery-kind', choices=['acknowledgment', 'completion', 'correction'])
    p.add_argument('--correction-of', help='original submitted outbox:STEP or action:ID')
    args = p.parse_args()
    try:
        if (args.goal or args.social or args.attach or args.reply_to or args.delivery_kind or args.correction_of) and args.action != 'signal-send':
            raise ValueError('--attach and --reply-to are for signal-send')
        if args.action in ('signal-lane-status', 'signal-send', 'signal-ask', 'automata-deploy', 'automata-rollback'):
            raw = sys.stdin.buffer.read(32769)
            if len(raw) > 32768: raise ValueError('request too large')
            payload = json.loads(raw)
            if not isinstance(payload, dict) or 'action' in payload: raise ValueError('object without action required')
        else:
            payload = {}
        if args.action == 'signal-guard':
            if not args.request_id: raise ValueError('conversation required')
            result = guard(args.request_id)
            print(json.dumps(result)); return 0
        if args.action == 'delivery-status':
            if not args.request_id: raise ValueError('delivery reference required')
            payload['reference'] = args.request_id
        elif args.action in ('status', 'signal-await', 'signal-release'):
            if not args.request_id: raise ValueError('request ID required')
            payload['request_id'] = args.request_id
        elif args.request_id:
            raise ValueError('unexpected request ID argument')
        for field in ('delivery_kind', 'correction_of'):
            value = getattr(args, field)
            if value is not None:
                if field in payload: raise ValueError('use flag or JSON ' + field + ', not both')
                payload[field] = value
        route = None
        reply_step = None
        if args.action == 'signal-send':
            if not isinstance(payload.get('message'), str) or not isinstance(payload.get('request_id'), str):
                raise ValueError('signal-send needs request_id, target and message')
            if args.goal:
                from custos_memory import Store, is_task
                import custos_own_waits as own
                goal_item = Store().find(args.goal)
                record_goal = goal_item[4]
                if not (own.active(goal_item) or (record_goal and record_goal['status'] == 'active' and is_task(record_goal))):
                    raise ValueError('--goal must name an active native goal')
            if args.goal:
                staged = Path(os.environ['IDENTITY_DIR']) / '.state' / 'staged-signal' / (hashlib.sha256(payload['request_id'].encode()).hexdigest() + '.json')
                if staged.exists() and staged.read_bytes() != json.dumps(payload, sort_keys=True, ensure_ascii=False).encode():
                    raise ValueError('staged request ID has a different payload; reconcile before sending')
            target = payload.get('target')
            if not (isinstance(target, str) and target.startswith(('dm:', 'group:'))):
                status, contacts = call({'action': 'signal-contacts'})
                target = resolve_target(target, contacts.get('destinations') or contacts.get('contacts') or (contacts if isinstance(contacts, list) else []))
            route = route_for(target)
            if args.goal and record_goal and record_goal['origin'].get('sender') == 'operator:ai-news-review':
                from custos_contact_guard import timestamp
                with Store().lock():
                    pending = own.pending_contact(Store(), target)
                if pending and timestamp(pending['priority_since']) < timestamp(record_goal['received_at']):
                    check_at = max(dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=1),
                                   dt.datetime.fromisoformat(pending.get('check_at') or pending['since']))
                    waiting = Store().wait({'goal_id': args.goal, 'resume_sender': '', 'check_at': check_at.isoformat(),
                        'reason': 'Batch optional news behind older contact goal ' + pending['goal_id'] + '; reassess that contact, resolve it if stale, then group news.'})
                    print(json.dumps({'ok': False, 'reason': 'older-contact-pending', 'contact_goal': pending['goal_id'], 'goal_wait': waiting})); return 1
            try:
                if args.social:
                    if args.reply_to or payload.get('reply_to') or payload.get('delivery_kind') or payload.get('correction_of'):
                        raise ValueError('--social is for unsolicited contact, not a correlated completion or correction')
                    social_guard(route)
                elif payload.get('delivery_kind') != 'correction':
                    guard(route)
            except ValueError as refusal:
                waiting = park_cooldown(args.goal, payload, target, args.social, refusal)
                print(json.dumps({'ok': False, 'error': 'not sent: ' + str(refusal), 'request_id': payload['request_id'], 'goal_wait': waiting}))
                return 1
            if args.attach:
                if 'attachments' in payload:
                    raise ValueError('use --attach or JSON attachments, not both')
                payload['attachments'] = attachments.read_files(args.attach)
            if 'attachments' in payload:
                attachments.validate(payload['attachments'])
            if args.reply_to:
                if 'reply_to' in payload:
                    raise ValueError('use --reply-to or JSON reply_to, not both')
                payload['reply_to'], reply_step = resolve_reply(args.reply_to, route)
        payload['action'] = args.action
        status, result = call(payload)
        result = explain_status(result)
        print(json.dumps(result, ensure_ascii=False))
        ok = status == 200 and result.get('ok')
        if ok and route is not None:
            if payload.get('attachments') or reply_step:
                record(route, payload['message'], payload['request_id'], result.get('phase', 'queued'),
                       payload.get('attachments'), reply_step, social=args.social, delivery_kind=payload.get('delivery_kind', 'completion'), correction_of=payload.get('correction_of'))
            else:
                record(route, payload['message'], payload['request_id'], result.get('phase', 'queued'), social=args.social, delivery_kind=payload.get('delivery_kind', 'completion'), correction_of=payload.get('correction_of'))
        return 0 if ok else 1
    except GuardRefusal as error:
        print(json.dumps(error.decision)); return 1
    except (ValueError, GoalMemoryError) as error:
        print(json.dumps({'ok': False, 'error': str(error)[:200]}))
        return 2
    except (OSError, http.client.HTTPException, RecursionError, subprocess.SubprocessError):
        print(json.dumps({'ok': False, 'error': 'Unavailable or invalid request; a write may be queued. Check status and reuse its exact request ID.'}))
        return 2


if __name__ == '__main__':
    sys.exit(main())
