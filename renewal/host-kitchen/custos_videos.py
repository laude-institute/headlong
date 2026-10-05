"""Private Wispwood video evidence. No decoder, URL fetch or guest paths."""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile

GROUP = 'cvH9Ko+CV/13CWJ7zQ5q1blR3jtedz03KCyJy8TOwL8='
ROOT = Path('/var/lib/custos-feedback-videos')
SOURCE = Path('/var/lib/custos-signal/data/attachments')
MAX_BYTES = 100 * 1024 * 1024
MIMES = {'video/mp4': '.mp4', 'video/quicktime': '.mov', 'video/webm': '.webm', 'video/3gpp': '.3gp'}

def candidates(attachments, group):
    if group != GROUP:
        return []
    return [{'id': a['id'], 'size': a['size'], 'mime': a['contentType']}
            for a in attachments if isinstance(a, dict)
            and a.get('contentType') in MIMES
            and isinstance(a.get('id'), str)
            and re.fullmatch(r'[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*', a['id'])
            and len(a['id']) <= 160 and type(a.get('size')) is int
            and 0 < a['size'] <= MAX_BYTES][:4]

def source_key(source_id):
    if not isinstance(source_id, str) or not re.fullmatch(r'signal:[0-9a-f]{64}', source_id):
        raise ValueError('Invalid Signal source')
    return source_id.split(':')[1]

def archive(item, root=ROOT, source=SOURCE):
    if item.get('group') != GROUP or not item.get('video_attachments'):
        return []
    key = source_key(item['request_id'])
    root.mkdir(mode=0o755, parents=True, exist_ok=True)
    manifest = root / (key + '.json')
    if manifest.exists():
        return json.loads(manifest.read_text())
    records = []
    for a in item['video_attachments']:
        if candidates([{'id': a['id'], 'size': a['size'], 'contentType': a['mime']}], GROUP) != [a]:
            raise ValueError('Invalid video metadata')
        fd = os.open(source / a['id'], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        tmp = None
        try:
            with os.fdopen(fd, 'rb') as inp:
                info = os.fstat(inp.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_size != a['size']:
                    raise ValueError('Video size/type mismatch')
                digest = hashlib.sha256()
                with tempfile.NamedTemporaryFile(dir=root, delete=False) as out:
                    tmp = Path(out.name)
                    total = 0
                    while True:
                        chunk = inp.read(1024 * 1024)
                        if not chunk:
                            break
                        total += len(chunk)
                        if total > MAX_BYTES:
                            raise ValueError('Video exceeds limit')
                        digest.update(chunk)
                        out.write(chunk)
                    out.flush()
                    os.fsync(out.fileno())
                if total != a['size']:
                    raise ValueError('Video changed during copy')
                sha = digest.hexdigest()
                dest = root / (sha + MIMES[a['mime']])
                os.replace(tmp, dest)
                records.append({'sha256': sha, 'size': total, 'mime': a['mime'], 'path': str(dest),
                                'source_id': item['request_id'], 'attachment_id': a['id']})
        finally:
            if tmp is not None:
                tmp.unlink(missing_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=root, delete=False) as out:
        json.dump(records, out, sort_keys=True)
        out.flush()
        os.fsync(out.fileno())
        os.fchmod(out.fileno(), 0o644)
        tmp = Path(out.name)
    os.replace(tmp, manifest)
    return records

def read(source_id, root=ROOT):
    return json.loads((root / (source_key(source_id) + '.json')).read_text())

def describe(records):
    lines = ['Original Signal video evidence (preserved for coding agents; not visually reviewed by Custos):']
    for r in records:
        lines += [f"- {r['mime']}, {r['size']} bytes; SHA-256 {r['sha256']}",
                  '  Source: ' + r['source_id'],
                  "  Retrieve from the Mac: ssh -i ~/.ssh/id_ed25519 user@192.168.86.44 'sudo -n cat " + r['path'] + "' > feedback" + Path(r['path']).suffix]
    return '\n'.join(lines)
