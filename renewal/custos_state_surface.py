#!/usr/bin/env python3
"""state-surface: one read of the wake state.

Reports, for each source: what is eligible NOW vs clock-blocked (with the
exact time it becomes eligible), so a wake starts clean instead of re-deriving
state. Sources:
  - todos (native mem)            fast, deterministic
  - PR queue (custos_github_prs)  fast, deterministic
  - lanes (host bot-thread via signal-lane-status + double-text guard via
    `chat guard`)  fast, deterministic; for targets with waiting goals /
    staged nudges: host bot-thread state, and when the social (initiate_after
    hours, cross-room) and completion (mind window, same-room) double-text
    guards reopen. NOTE: signal-lane-status alone does NOT reflect the
    double-text guard - that is enforced at send time via `chat guard`.
  - goals (custos-memory pending --json)  deterministic; opt-in via
    --goals, cached to .state-surface-goals.json (TTL 30 min)
  - receipts (custos-actions delivery-status)  on demand via --receipt REF

No model calls. Goal inspection may reconcile structured waits; its cache is a display aid, not eligibility authority.
"""
import hashlib, json, os, re, subprocess, sys
from pathlib import Path
from datetime import datetime, timedelta, timezone

NOW = datetime.now(timezone.utc)
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(SCRIPT_DIR, '.state-surface-goals.json')
CACHE_TTL = 0  # Eligibility and event waits must be fresh.

def run(cmd, timeout=30, stdin=None):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           input=stdin)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"

def parse_iso(s, ref=None):
    """Parse ISO timestamps.

    Accepts:
      - full ISO: 2026-10-05T23:27:33.002984+00:00 / ...Z
      - space ISO: 2026-10-05 19:10:54Z
      - bare time: 19:10:54  (interpreted as today in UTC, relative to ref)
    """
    if not s:
        return None
    s = s.strip()
    ref = ref or NOW
    if re.match(r'^\d{2}:\d{2}(?::\d{2})?$', s):
        fmt = '%H:%M:%S' if re.match(r'^\d{2}:\d{2}:\d{2}$', s) else '%H:%M'
        try:
            t = datetime.strptime(s, fmt)
            return t.replace(year=ref.year, month=ref.month, day=ref.day, tzinfo=timezone.utc)
        except ValueError:
            return None
    try:
        if s.endswith('Z'):
            s = s[:-1] + '+00:00'
        d = datetime.fromisoformat(s)
        if d.tzinfo is None:
            d = d.replace(tzinfo=timezone.utc)
        return d
    except ValueError:
        return None

def hhmm(d):
    if not d:
        return '?'
    u = d.astimezone(timezone.utc)
    if u.date() == NOW.date():
        return u.strftime('%H:%M:%SZ')
    return u.strftime('%Y-%m-%d %H:%M:%SZ')

def delta(d):
    if d is None:
        return '?'
    s = int((d - NOW).total_seconds())
    if s < 0:
        return f"now ({-s//3600}h ago)"
    if s < 90:
        return f"in {s}s"
    if s < 3600:
        return f"in {s//60}m"
    return f"in {s//3600}h{(s%3600)//60:02d}m"

def collect_goals(use_cache=True):
    if use_cache and os.path.exists(CACHE):
        try:
            with open(CACHE) as f:
                c = json.load(f)
            if NOW.timestamp() - c.get('ts', 0) < CACHE_TTL:
                return c.get('data'), 'cache'
        except Exception:
            pass
    rc, so, se = run(['custos-memory', 'pending', '--json'], timeout=90)
    if rc == 0:
        try:
            data = json.loads(so)
        except Exception as e:
            return f"parse error: {e}", 'fresh'
        try:
            with open(CACHE, 'w') as f:
                json.dump({'ts': NOW.timestamp(), 'data': data}, f)
        except Exception:
            pass
        return data, 'fresh'
    if os.path.exists(CACHE):
        try:
            with open(CACHE) as f:
                c = json.load(f)
            return c.get('data'), 'cache (stale; fresh read failed: ' + se[:80] + ')'
        except Exception:
            pass
    return f"command failed rc={rc}: {se[:120]}", 'fresh'

def collect_todos():
    rc, so, se = run(['mem', 'list', '--type', 'todo', '-s'], timeout=30)
    if rc != 0:
        return None, f"mem list failed rc={rc}: {se[:120]}"
    todos = []
    for line in so.splitlines():
        m = re.match(r'^\s*(\S+)\s+(\S+)\s+(\S+)\s+\[todo\]\s+(.*)$', line)
        if not m:
            continue
        _date, _time, tid, summary = m.groups()
        rc2, body, _ = run(['mem', 'show', tid], timeout=30)
        if rc2 != 0:
            todos.append({'id': tid, 'summary': summary, 'fire': None,
                          'fire_raw': None, 'expired': False})
            continue
        fire_raw = None
        for pat in (r'after\s+(\d{2}:\d{2}:\d{2})Z',
                    r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|\+00:00))',
                    r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}(?::\d{2})?Z)'):
            fm = re.search(pat, body)
            if fm:
                fire_raw = fm.group(1)
                break
        fire = parse_iso(fire_raw)
        until_m = re.search(r'^until:\s*(\d{4}-\d{2}-\d{2})', body, re.M)
        expired = False
        if until_m:
            try:
                ud = datetime.strptime(until_m.group(1), '%Y-%m-%d').replace(tzinfo=timezone.utc)
                expired = NOW.date() > ud.date()
            except ValueError:
                pass
        todos.append({'id': tid, 'summary': summary, 'fire': fire,
                      'fire_raw': fire_raw, 'expired': expired})
    return todos, None

def collect_pr():
    rc, so, se = run(['python3', '/opt/custos/current/renewal/custos_github_prs.py',
                      '--queue', '--offset', '0', '--limit', '10'], timeout=60)
    if rc != 0:
        return None, f"command failed rc={rc}: {se[:120]}"
    try:
        q = json.loads(so)
    except Exception as e:
        return None, f"parse error: {e}"
    return q, None

def route_for(target):
    return 'signal-' + hashlib.sha256(target.encode()).hexdigest()[:24]

def policy_guard_hours():
    try:
        p = json.loads((Path(os.environ['IDENTITY_DIR']) / 'social-policy.json').read_text())
    except Exception:
        p = {}
    social = p.get('initiate_after_hours', 12)
    if not isinstance(social, int):
        social = 12
    mind = p.get('mind_double_text_hours', 2)
    if not isinstance(mind, int):
        mind = 2
    return social, mind

def parse_guard_reopen(msg):
    m = re.search(r'reopens at (\d{2}:\d{2}(?::\d{2})?)Z', msg)
    if not m:
        return None
    d = parse_iso(m.group(1))
    if d is None:
        return None
    if d < NOW:
        d = d + timedelta(days=1)
    return d

def guard_check(route, hours, cross_room):
    env = dict(os.environ)
    env['CHAT_DOUBLE_TEXT_GUARD_HOURS'] = str(hours)
    env['CHAT_GUARD_CROSS_ROOM'] = '1' if cross_room else '0'
    try:
        p = subprocess.run(['custos-actions', 'signal-guard', route], capture_output=True,
                           text=True, timeout=30, env=env)
        result = json.loads(p.stdout)
        if not isinstance(result.get('ok'), bool): raise ValueError('no decision')
        return {'open': result['ok'] and p.returncode == 0, 'state': result.get('state', 'unknown'),
                'reopen': parse_iso(result.get('resume_at')), 'channel': result.get('channel'),
                'raw': result.get('meaning') or result.get('error', '')}
    except (subprocess.TimeoutExpired, ValueError, TypeError):
        return {'open': False, 'state': 'unknown', 'reopen': None, 'raw': 'guard unavailable; no eligibility claim'}

def collect_lanes(targets):
    social_h, mind_h = policy_guard_hours()
    lanes = []
    for t in sorted(set(targets)):
        entry = {'target': t}
        rc, so, se = run(['custos-actions', 'signal-lane-status'],
                         timeout=30, stdin=json.dumps({'target': t}))
        if rc == 0:
            try:
                entry['host'] = json.loads(so)
            except Exception:
                entry['host'] = {'ok': False, 'error': (se or so)[:80]}
        else:
            entry['host'] = {'ok': False, 'error': (se or so)[:80]}
        route = route_for(t)
        entry['social'] = guard_check(route, social_h, True)
        entry['completion'] = guard_check(route, mind_h, False)
        lanes.append(entry)
    return lanes

def collect_receipt(ref):
    rc, so, se = run(['custos-actions', 'delivery-status', ref], timeout=30)
    if rc != 0:
        return None, f"command failed rc={rc}: {se[:120]}"
    try:
        return json.loads(so), None
    except Exception as e:
        return None, f"parse error: {e}"

def fmt_receipt(r):
    out = []
    out.append(f"  {r.get('reference','?')}: phase={r.get('phase')} "
               f"terminal={r.get('delivery_state',{}).get('terminal')}")
    rec = r.get('receipt') or {}
    for res in rec.get('results', []):
        addr = res.get('recipientAddress', {})
        who = addr.get('username') or addr.get('number') or addr.get('uuid') or '?'
        out.append(f"      {who}: {res.get('type')}")
    out.append(f"      meaning: {r.get('delivery_state',{}).get('meaning','')[:110]}")
    return out

def text_output(now, goals, goals_src, todos, todos_err, pr, pr_err, lanes, receipts):
    out = [f"state-surface @ {now.strftime('%Y-%m-%d %H:%M:%SZ')}"]
    if goals is not None:
        out.append(f"\nGOALS (custos-memory pending; {goals_src}):")
        if isinstance(goals, str):
            out.append(f"  {goals}")
        else:
            for g in goals.get('goals', []):
                out.append(f"  ACTIVE {g.get('goal_id','?')}: {g.get('summary','')[:90]}")
            for g in goals.get('deferred', []):
                out.append(f"  DEFERRED {g.get('goal_id','?')}: {g.get('summary','')[:90]}")
            for g in goals.get('waiting', []):
                ca = parse_iso(g.get('check_at'))
                out.append(f"  WAITING {g.get('goal_id','?')}: {g.get('summary','')[:70]}")
                out.append(f"      reason: {g.get('reason','')[:80]}")
                condition = ('reconsider at ' + hhmm(ca) if ca else 'event wait; no clock deadline')
                for field in ('receipt', 'signal_target', 'dependency_goal', 'resume_sender'):
                    if g.get(field): condition += '; ' + field + '=' + g[field]
                out.append('      ' + condition)
    out.append("\nTODOS (native mem):")
    if todos_err:
        out.append(f"  {todos_err}")
    else:
        for t in todos:
            if t['fire']:
                out.append(f"  {t['id']} {t['summary'][:70]}")
                out.append(f"      body timestamp {hhmm(t['fire'])} (historical hint, not eligibility)"
                           + (" [EXPIRED]" if t['expired'] else ""))
            else:
                out.append(f"  {t['id']} {t['summary'][:90]} (no fire time in body)"
                           + (" [EXPIRED]" if t['expired'] else ""))
    out.append("\nPR QUEUE (custos_github_prs):")
    if pr_err:
        out.append(f"  {pr_err}")
    else:
        h = pr.get('health', {})
        out.append(f"  pending={h.get('pending')} total={pr.get('total')} "
                   f"older_than_day={pr.get('older_than_day')} "
                   f"health.alerted={h.get('alerted')} (failures={len(h.get('failures', []))})")
        for it in pr.get('items', []):
            s = it.get('summary', {})
            out.append(f"  {it.get('id','?')} age={it.get('age_hours')}h state={s.get('state')} "
                       f"review={s.get('review')} authored_feedback={s.get('authored_feedback')}")
    if lanes:
        out.append("\nLANES (signal, now):")
        for l in lanes:
            t = l['target']
            host = l.get('host', {})
            if host.get('ok') is False and host.get('error'):
                host_state = f"host-error {host['error'][:50]}"
            else:
                host_state = 'host-blocked' if host.get('blocked') else 'host-open'
            out.append(f"  {t}: {host_state}")
            for kind in ('completion', 'social'):
                g = l.get(kind, {})
                if g.get('open'):
                    out.append(f"      {kind}-guard: open")
                else:
                    rp = g.get('reopen')
                    if rp:
                        out.append(f"      {kind}-guard: closed reopens {hhmm(rp)} ({delta(rp)})")
                    else:
                        out.append(f"      {kind}-guard: {g.get('state', 'unknown')} ({g.get('raw','')[:100]})")
    if receipts:
        out.append("\nRECEIPTS:")
        for ref, r, err in receipts:
            if err:
                out.append(f"  {ref}: {err}")
            else:
                out.extend(fmt_receipt(r))
    return '\n'.join(out)

def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--goals', action='store_true',
                    help='include the deterministic goal store (fresh read)')
    ap.add_argument('--no-cache', action='store_true',
                    help='force a fresh goals read')
    ap.add_argument('--receipt', action='append', default=[], metavar='REF',
                    help='check a delivery receipt (outbox:STEP or action:ID); repeatable')
    ap.add_argument('--json', action='store_true', help='machine-readable output')
    args = ap.parse_args()

    goals, goals_src = (None, None)
    if args.goals:
        goals, goals_src = collect_goals(use_cache=not args.no_cache)

    todos, todos_err = collect_todos()
    pr, pr_err = collect_pr()

    targets = []
    if isinstance(goals, dict):
        for g in goals.get('waiting', []):
            if g.get('signal_target'):
                targets.append(g['signal_target'])
    lanes = collect_lanes(targets) if targets else []

    receipts = []
    for ref in args.receipt:
        r, err = collect_receipt(ref)
        receipts.append((ref, r, err))

    if args.json:
        print(json.dumps({
            'now': NOW.isoformat(),
            'goals': goals, 'goals_src': goals_src,
            'todos': todos, 'todos_err': todos_err,
            'pr': pr, 'pr_err': pr_err,
            'lanes': lanes, 'receipts': [{'ref': r, 'data': d, 'err': e} for r, d, e in receipts],
        }, indent=2, default=str))
    else:
        print(text_output(NOW, goals, goals_src, todos, todos_err, pr, pr_err, lanes, receipts))

if __name__ == '__main__':
    main()
