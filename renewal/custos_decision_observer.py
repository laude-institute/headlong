"""Failure-isolated responder hook. No decisions enter the response plan."""
import json
import os
from pathlib import Path
import subprocess


def observe_response(incoming, messages, plan, trigger):
    root = Path(os.environ.get('HEADLONG_ROOT', '/opt/custos/current/runtime/headlong'))
    command = root / 'bin/decide'
    if not command.is_file():
        return
    payload = {'request': incoming.get('content', ''), 'messages': messages,
               'response': plan.get('reply', ''), 'images_present': bool(incoming.get('images'))}
    if not payload['response']:
        return
    try:
        subprocess.run([str(command), '-', '--observe', 'response', '--scope', 'responder',
                        '--run-id', str(trigger)], input=json.dumps(payload), text=True,
                       stdout=subprocess.DEVNULL, timeout=3, check=False)
    except (OSError, subprocess.SubprocessError, ValueError):
        # The normal persistence/permission/delivery path remains authoritative.
        pass
