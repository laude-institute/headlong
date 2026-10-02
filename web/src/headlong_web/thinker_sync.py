"""Compare an identity's installed thinkers against the bundled copies and
pull updates in — the web replacement for SSH-ing to the box and hand-copying
thinker files after a deploy.

"Version" is the last git commit touching the bundled thinker's dir (short
hash + date); identities don't track versions, so the identity side reports
drift by file-content comparison: in_sync / outdated / not_installed, plus
local_only for identity thinkers with no bundled counterpart.

Per-identity state is never overwritten: `subscriptions.jsonl` (carries the
injected traj_id) and the `disabled` marker survive a pull. A bundled
`disabled` marker is inherited on first install only; removing it is an
identity opt-in that later pulls preserve. The shared `_lib` dir is compared
and synced like a thinker — step scripts source it at wakeup, so a stale _lib
is as real a drift as a stale step. File writes are atomic (temp + rename), so
a thinker mid-step keeps executing its old inode and picks the new code up
next wakeup.
"""

import json
import os
import re
import subprocess
import tempfile
import time
from hashlib import sha256
from pathlib import Path

from headlong_web.env import getenv

# Names are path segments; allow the leading underscore of _lib but nothing
# resembling traversal.
SYNC_NAME_RE = re.compile(r"^[a-z0-9_][a-z0-9_-]*$")

_PRESERVE = {"subscriptions.jsonl", "disabled"}
_EXECUTABLE = {"step", "start", "stop"}

_REPO_ROOT = Path(__file__).resolve().parents[3]

_version_cache: dict = {"ts": 0.0, "byname": {}}
_VERSION_TTL_S = 60


def bundled_root() -> Path | None:
    """Where pristine thinkers live: env override, the repo this server runs
    from, or the installed templates."""
    override = getenv("HEADLONG_WEB_THINKERS_SRC")
    candidates = [Path(override)] if override else []
    candidates += [_REPO_ROOT / "thinkers", Path.home() / ".headlong-thinkers"]
    for cand in candidates:
        if cand.is_dir():
            return cand
    return None


def _digest(path: Path) -> str | None:
    try:
        return sha256(path.read_bytes()).hexdigest()
    except OSError:
        return None


def _sync_files(bundled_dir: Path) -> list[Path]:
    """Bundled files a pull would copy (relative), per-identity state excluded."""
    files = []
    for path in sorted(bundled_dir.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(bundled_dir)
        if rel.name in _PRESERVE or rel.name.startswith("."):
            continue
        files.append(rel)
    return files


def _changed_files(bundled_dir: Path, installed_dir: Path) -> list[str]:
    changed = []
    for rel in _sync_files(bundled_dir):
        if _digest(bundled_dir / rel) != _digest(installed_dir / rel):
            changed.append(str(rel))
    return changed


def _bundled_version(root: Path, name: str) -> str | None:
    """Last git commit touching the bundled dir, as 'shorthash · date'."""
    now = time.time()
    if now - _version_cache["ts"] > _VERSION_TTL_S:
        _version_cache.update(ts=now, byname={})
    byname = _version_cache["byname"]
    if name in byname:
        return byname[name]
    version = None
    try:
        out = subprocess.run(
            ["git", "-C", str(root), "log", "-1", "--format=%h · %cs", "--", name],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if out.returncode == 0 and out.stdout.strip():
            version = out.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        pass
    byname[name] = version
    return version


def status(identity_dir: Path) -> dict:
    root = bundled_root()
    installed_root = identity_dir / "thinkers"
    entries = []
    bundled_names: set[str] = set()

    if root is not None:
        for bundled_dir in sorted(root.iterdir()):
            if not bundled_dir.is_dir():
                continue
            name = bundled_dir.name
            bundled_names.add(name)
            installed_dir = installed_root / name
            if not installed_dir.is_dir():
                state = "not_installed"
                changed = [str(r) for r in _sync_files(bundled_dir)]
            else:
                changed = _changed_files(bundled_dir, installed_dir)
                state = "outdated" if changed else "in_sync"
            entries.append(
                {
                    "name": name,
                    "status": state,
                    "changed_files": changed,
                    "bundled_version": _bundled_version(root, name),
                }
            )

    if installed_root.is_dir():
        for installed_dir in sorted(installed_root.iterdir()):
            if installed_dir.is_dir() and installed_dir.name not in bundled_names:
                entries.append(
                    {
                        "name": installed_dir.name,
                        "status": "local_only",
                        "changed_files": [],
                        "bundled_version": None,
                    }
                )

    return {
        "bundled_root": str(root) if root else None,
        "thinkers": entries,
        "note": "Pull replaces code files only; subscriptions.jsonl and the "
        "disabled marker stay. Restart thinkers to pick up new code.",
    }


def _atomic_copy(src: Path, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    content = src.read_bytes()
    fd, tmp_name = tempfile.mkstemp(
        prefix=f".{dest.name}.sync-tmp-", dir=dest.parent
    )
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
        executable = dest.name in _EXECUTABLE or os.access(src, os.X_OK)
        tmp.chmod(0o755 if executable else 0o644)
        os.replace(tmp, dest)
    finally:
        tmp.unlink(missing_ok=True)


def _install_subscriptions(bundled_dir: Path, installed_dir: Path, identity_dir: Path) -> None:
    """Fresh install only: copy subscriptions.jsonl and inject the identity's
    root traj_id, mirroring tools/identity's _ensure_thinkers."""
    src = bundled_dir / "subscriptions.jsonl"
    dest = installed_dir / "subscriptions.jsonl"
    if dest.exists() or not src.is_file():
        return
    root_traj = None
    try:
        for line in (identity_dir / "info.txt").read_text().splitlines():
            if line.startswith("root_trajectory="):
                root_traj = line.split("=", 1)[1].strip()
    except OSError:
        pass
    lines = []
    for line in src.read_text().splitlines():
        if not line.strip():
            continue
        try:
            sub = json.loads(line)
            if root_traj and "traj_id" not in sub:
                sub["traj_id"] = root_traj
            lines.append(json.dumps(sub))
        except ValueError:
            lines.append(line)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text("".join(f"{line}\n" for line in lines))


def sync(identity_dir: Path, names: list[str]) -> dict:
    root = bundled_root()
    if root is None:
        raise FileNotFoundError("No bundled thinkers directory found")
    current = status(identity_dir)
    by_name = {t["name"]: t for t in current["thinkers"]}
    if not names:
        names = [
            t["name"]
            for t in current["thinkers"]
            if t["status"] in ("outdated", "not_installed")
        ]

    results = []
    for name in names:
        entry = by_name.get(name)
        if entry is None or entry["status"] == "local_only":
            results.append({"name": name, "action": "skipped", "files": []})
            continue
        bundled_dir = root / name
        installed_dir = identity_dir / "thinkers" / name
        fresh = entry["status"] == "not_installed"
        copied = []
        for rel in _sync_files(bundled_dir):
            dest = installed_dir / rel
            if _digest(bundled_dir / rel) != _digest(dest):
                _atomic_copy(bundled_dir / rel, dest)
                copied.append(str(rel))
        if fresh:
            _install_subscriptions(bundled_dir, installed_dir, identity_dir)
            disabled_default = bundled_dir / "disabled"
            if disabled_default.is_file():
                _atomic_copy(disabled_default, installed_dir / "disabled")
        results.append(
            {
                "name": name,
                "action": "installed" if fresh else ("updated" if copied else "unchanged"),
                "files": copied,
            }
        )
    return {"ok": True, "results": results}
