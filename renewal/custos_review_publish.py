"""Publish one authorized review per repository/PR/head/disposition with readback."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import subprocess

from custos_dream import write_json
from custos_publication_evidence import capture

STATES = {'COMMENT': 'COMMENTED', 'APPROVE': 'APPROVED', 'REQUEST_CHANGES': 'CHANGES_REQUESTED'}


def api(path, payload=None, pages=False):
    cmd = ['gh', 'api', path]
    if payload is not None: cmd += ['--method', 'POST', '--input', '-']
    if pages: cmd += ['--paginate', '--slurp']
    result = subprocess.run(cmd, input=json.dumps(payload) if payload is not None else None,
                            capture_output=True, text=True, timeout=60, check=True)
    value = json.loads(result.stdout)
    return [r for page in value for r in page] if pages else value


def publish(repo, pr, head, event, body, root, mode, actionable=False, update_of=None, update_evidence=None):
    if repo != '1f916-ai/1f916' or mode not in {'reviews', 'actionable'}:
        raise ValueError('helper only covers authorized 1f916-ai/1f916 publication modes')
    if mode == 'actionable' and (not actionable or event == 'APPROVE'):
        raise ValueError('actionable mode requires a finding; clean approvals stay private')
    if event not in STATES or pr < 1 or not re.fullmatch('[a-f0-9]{40}', head): raise ValueError('invalid review identity')
    if not body.strip() or len(body.encode()) > 60000 or head not in body: raise ValueError('bounded evidence body must include full reviewed head')
    if bool(update_of) != bool(update_evidence and update_evidence.strip()): raise ValueError('a same-disposition update needs prior review ID and new evidence')
    state = STATES[event]
    key = hashlib.sha256(f'{repo}:{pr}:{head}:{state}:{update_of or "initial"}'.encode()).hexdigest()
    directory = Path(root); directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    journal = directory / (key + '.json')
    marker = f'custos-pr-review:{pr}:{head}:{state}' + (f':update:{update_of}' if update_of else '')
    with (directory / (key + '.lock')).open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if api('user').get('login') != 'custos-1f916': raise ValueError('wrong publication account')
        current = api(f'repos/{repo}/pulls/{pr}')
        if current['head']['sha'] != head: raise ValueError('head changed; review the delta before publishing')
        if event == 'APPROVE' and current['user']['login'] == 'custos-1f916': raise ValueError('cannot independently approve your own PR')
        reviews = api(f'repos/{repo}/pulls/{pr}/reviews?per_page=100', pages=True)
        owned = [r for r in reviews if r.get('user', {}).get('login') == 'custos-1f916' and r.get('commit_id') == head and r.get('submitted_at')]
        prior = [r for r in owned if r.get('state') == state]
        if update_of:
            original = next((r for r in prior if r['id'] == update_of), None)
            if not original: raise ValueError('update must reference your same-head, same-disposition review')
            if body.strip() == original.get('body', '').split('\n\n<!-- custos-pr-review:')[0].strip():
                raise ValueError('unchanged body is not new evidence')
            prior = [r for r in prior if marker in r.get('body', '')]
        if prior:
            result = capture(repo, pr, head, prior[-1]['id'])
            write_json(journal, {'phase': 'confirmed', 'receipt': result, 'deduplicated': True})
            return {**result, 'deduplicated': True}
        if journal.exists():
            raise ValueError('prior attempt is not reconciled on GitHub; do not resend or change IDs')
        # Read ordinary comments too: an old marked review may have been posted
        # through the issue-comment endpoint. Require deliberate reconciliation.
        comments = api(f'repos/{repo}/issues/{pr}/comments?per_page=100', pages=True)
        legacy = f'custos-pr-review:{pr}:{head}'
        if not owned and any(r.get('user', {}).get('login') == 'custos-1f916' and legacy in r.get('body', '') for r in comments):
            raise ValueError('existing marked comment needs reconciliation before a review submission')
        if api(f'repos/{repo}/pulls/{pr}')['head']['sha'] != head: raise ValueError('head changed during preflight')
        final = body.strip()
        if update_of: final += f'\n\nUpdate to review {update_of}: {update_evidence.strip()}'
        final += '\n\n<!-- ' + marker + ' -->'
        write_json(journal, {'phase': 'attempting', 'repo': repo, 'pr': pr, 'head': head, 'state': state,
                             'marker': marker, 'body_sha256': hashlib.sha256(final.encode()).hexdigest()})
        # The preimage journal survives a timeout/crash; subsequent calls read
        # GitHub first and never blindly retry an uncertain POST.
        response = api(f'repos/{repo}/pulls/{pr}/reviews', {'commit_id': head, 'event': event, 'body': final})
        result = capture(repo, pr, head, response['id'])
        result['current_head'] = api(f'repos/{repo}/pulls/{pr}')['head']['sha']
        result['deduplicated'] = False
        write_json(journal, {'phase': 'confirmed', 'receipt': result})
        return result


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--repo', required=True); p.add_argument('--pr', required=True, type=int)
    p.add_argument('--head', required=True); p.add_argument('--event', choices=STATES, required=True)
    p.add_argument('--body-file', required=True); p.add_argument('--actionable', action='store_true')
    p.add_argument('--update-of', type=int); p.add_argument('--update-evidence')
    a = p.parse_args(argv)
    try:
        config = json.loads(Path('/var/lib/custos/config/observations.json').read_text())
        result = publish(a.repo, a.pr, a.head, a.event, Path(a.body_file).read_text(),
                         Path(os.environ['IDENTITY_DIR']) / '.state' / 'review-publications',
                         config.get('github_prs', {}).get('publication'), a.actionable, a.update_of, a.update_evidence)
        print(json.dumps(result)); return 0
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print(json.dumps({'ok': False, 'error': str(error) if isinstance(error, ValueError) else type(error).__name__,
                          'retry': 'Read back the original review/marker; an uncertain submission must not be repeated.'})); return 1

if __name__ == '__main__':
    sys.exit(main())
