"""Mutations: shell out to the repo's bash CLIs (thinkers, chat, identity,
headlong-killall) with the same environment `identity shell` would set.

Process management stays in bash — this module only builds env, serializes
concurrent mutations per identity, and maps CLI failures to HTTP errors.
"""

import json
import os
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from fastapi import HTTPException

from headlong_web import envfile
from headlong_web.discovery import IdentityInfo, _parse_info_txt
from headlong_web.env import getenv

# Repo layout: <repo>/web/src/headlong_web/control.py -> <repo>/bin
BIN_DIR = Path(
    getenv("HEADLONG_BIN_DIR") or Path(__file__).resolve().parents[3] / "bin"
)
# Management CLIs (identity, headlong-killall) live in <repo>/tools, apart from
# the core agent tools in bin/.
TOOLS_DIR = Path(
    getenv("HEADLONG_TOOLS_DIR") or Path(__file__).resolve().parents[3] / "tools"
)

DEFAULT_TIMEOUT = 60
# tar+gzip over a long-lived identity's trajectories can take a while
EXPORT_IMPORT_TIMEOUT = 300

# Serialize start/stop per identity: cmd_stop rewrites run/active_thinkers
# with a non-atomic grep>tmp;mv, so concurrent mutations can clobber it.
_locks_guard = threading.Lock()
_identity_locks: dict[str, threading.Lock] = {}


def identity_lock(identity_id: str) -> threading.Lock:
    with _locks_guard:
        lock = _identity_locks.get(identity_id)
        if lock is None:
            lock = threading.Lock()
            _identity_locks[identity_id] = lock
        return lock


def identity_env(identity: IdentityInfo, root: Path | None = None) -> dict[str, str]:
    """Replicate the env exports of `identity shell` (tools/identity:302-325)."""
    info = _parse_info_txt(identity.path / "info.txt")
    d = str(identity.path)
    root_traj = info.get("root_trajectory", "")
    env = os.environ.copy()
    env.update(
        {
            "SHELLM_WEB_SERVE_ROOT": str(root) if root else "",
            "IDENTITY_DIR": d,
            "IDENTITY_NAME": info.get("name", identity.path.name),
            "MEM_DIR": f"{d}/memories",
            "SKILLS_DIR": f"{d}/skills",
            "SKILLS_KERNEL_DIR": f"{d}/kernel",
            "TRAJ_DIR": f"{d}/trajectories",
            "TRAJ_ID": root_traj,
            "ROOT_TRAJ_ID": root_traj,
            "THINKERS_DIR": f"{d}/thinkers",
            "SHELLM_HOME": f"{d}/.shellm",
            "SKILLSRC": f"{d}/skills/.skillsrc",
            "SHELLM_TRAJ_DIR": f"{d}/trajectories",
            "SHELLM_ENVS_DIR": f"{d}/.shellm/envs",
            "SHELLM_WORKDIRS_DIR": f"{d}/.shellm/workdirs",
            "SHELLM_BROKER_DIR": f"{d}/.shellm/docker-broker",
            "SHELLM_CONF_DIR": f"{d}/.shellm",
            "CHATRC": f"{d}/chat/.chatrc",
            "THINK_TICK_INTERVAL": info.get("interval", "0"),
            "THINK_CONTEXT_TAIL": os.environ.get("THINK_CONTEXT_TAIL", "30"),
            "PATH": f"{BIN_DIR}:{TOOLS_DIR}:{env.get('PATH', '')}",
        }
    )
    # Pin THINK_MODEL only when something actually specifies it. A fabricated
    # default here would shadow SHELLM_MODEL from the serve root's .env
    # (sourced later by _ENV_WRAPPER), which the step scripts fall back to.
    think_model = info.get("think_model") or env.get("SHELLM_MODEL")
    if think_model:
        env["THINK_MODEL"] = think_model
    return env


# Source .env files before exec'ing the target CLI: the serve root's first
# (llm/shellm load .env from cwd, and terminal sessions run from the repo
# root), then the identity's own, so identity-specific keys win.
_ENV_WRAPPER = (
    "set -a; "
    '[ -n "$SHELLM_WEB_SERVE_ROOT" ] && [ -f "$SHELLM_WEB_SERVE_ROOT/.env" ] '
    '&& . "$SHELLM_WEB_SERVE_ROOT/.env"; '
    '[ -f "$IDENTITY_DIR/.env" ] && . "$IDENTITY_DIR/.env"; '
    "set +a; "
    'exec "$0" "$@"'
)


def _wrap(cli: str, *args: str) -> list[str]:
    return ["bash", "-c", _ENV_WRAPPER, str(BIN_DIR / cli), *args]


# --- systemd-managed dispatchers -------------------------------------------
# On provisioned boxes HEADLONG_THINKERSCTL (legacy SHELLM_THINKERSCTL) points
# at a root-owned wrapper
# (deploy/headlong-thinkersctl, sudo rule in deploy/sudoers-headlong-thinkers)
# that maps start/stop/restart/is-active onto `systemctl <action>
# headlong-thinkers@<identity>`. Routing the dispatcher lifecycle through it
# gives each mind its own cgroup instead of headlong-web's — a dash-started
# dispatcher used to die orphaned when this service was OOM-killed or
# restarted (2026-08-10 outage). Unset (dev, tests): the direct CLI paths
# below behave exactly as before.


def _thinkersctl_path() -> str:
    return getenv("HEADLONG_THINKERSCTL", "")


def _thinkersctl(
    action: str, identity_name: str, timeout: int = DEFAULT_TIMEOUT
) -> subprocess.CompletedProcess:
    # HEADLONG_THINKERSCTL_SUDO (legacy SHELLM_THINKERSCTL_SUDO) exists for
    # tests, which can't sudo; empty string means "run the wrapper directly".
    sudo = getenv("HEADLONG_THINKERSCTL_SUDO", "sudo -n").split()
    cmd = [*sudo, _thinkersctl_path(), action, identity_name]
    try:
        return subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
    except subprocess.TimeoutExpired as exc:
        raise HTTPException(
            status_code=500,
            detail={"message": f"headlong-thinkersctl {action} timed out after {timeout}s"},
        ) from exc


def _unit_active(identity_name: str) -> bool:
    return _thinkersctl("is-active", identity_name).returncode == 0


def run_cli(
    cmd: list[str],
    env: dict[str, str],
    cwd: Path,
    *,
    stdin_text: str | None = None,
    timeout: int = DEFAULT_TIMEOUT,
) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            cmd,
            env=env,
            cwd=str(cwd),
            input=stdin_text,
            stdin=subprocess.DEVNULL if stdin_text is None else None,
            capture_output=True,
            text=True,
            timeout=timeout,
            # New session so backgrounded children (the dispatcher) survive
            # uvicorn Ctrl-C / --reload, which signal the whole process group.
            start_new_session=True,
        )
    except subprocess.TimeoutExpired as exc:
        raise HTTPException(
            status_code=500,
            detail={"message": f"{cmd[3] if len(cmd) > 3 else cmd[0]} timed out after {timeout}s"},
        ) from exc


def _raise_for_failure(proc: subprocess.CompletedProcess) -> None:
    if proc.returncode == 0:
        return
    stderr_lines = [line for line in (proc.stderr or "").splitlines() if line.strip()]
    message = stderr_lines[-1] if stderr_lines else f"exit code {proc.returncode}"
    raise HTTPException(
        status_code=409,
        detail={
            "message": message,
            "stderr": proc.stderr,
            "exit_code": proc.returncode,
        },
    )


def _result(action: str, names: list[str], proc: subprocess.CompletedProcess) -> dict:
    return {
        "ok": True,
        "action": action,
        "names": names,
        "exit_code": proc.returncode,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
    }


def thinkers_start(
    root: Path,
    identity: IdentityInfo,
    names: list[str],
    no_self_trigger: bool = False,
) -> dict:
    args = ["start"]
    if no_self_trigger:
        args.append("--no-self-trigger")
    args.extend(names)
    with identity_lock(identity.id):
        # --no-self-trigger changes how the dispatcher itself is armed,
        # which the fixed unit definition can't express — that debug path
        # keeps the direct CLI (and its old cgroup caveat).
        if _thinkersctl_path() and not no_self_trigger and not _unit_active(identity.path.name):
            # Fresh start through the unit: its ExecStart arms the
            # dispatcher in its own cgroup and kicks every enabled thinker
            # once, so no CLI pass is needed. (A subset request still
            # brings up all enabled thinkers — acceptable for a mind that
            # was fully down.)
            proc = _thinkersctl("start", identity.path.name, timeout=150)
            _raise_for_failure(proc)
            return _result("start", names, proc)
        # Dispatcher already running (or no unit wrapper): the CLI named
        # start only activates and kicks the requested thinkers — a
        # short-lived mutation, safe to run from this service's cgroup.
        proc = run_cli(_wrap("thinkers", *args), identity_env(identity, root), root)
    _raise_for_failure(proc)
    return _result("start", names, proc)


def thinkers_stop(
    root: Path, identity: IdentityInfo, names: list[str], force: bool = False
) -> dict:
    """Default is the CLI's drain stop (deactivate now, in-flight steps
    finish in a detached reaper); force kills them immediately."""
    args = ["stop"]
    if force:
        args.append("--force")
    args.extend(names)
    with identity_lock(identity.id):
        if (
            _thinkersctl_path()
            and not names
            and not force
            and _unit_active(identity.path.name)
        ):
            # Whole-identity drain stop of a unit-managed dispatcher:
            # systemd runs ExecStop (thinkers stop + a wait for draining
            # steps) and then sweeps the unit's cgroup, so nothing can be
            # left over. Timeout tracks the unit's TimeoutStopSec=200.
            proc = _thinkersctl("stop", identity.path.name, timeout=210)
            _raise_for_failure(proc)
            return _result("stop", names, proc)
        # Named stop, --force, or no unit: direct CLI. If this ends up
        # killing a unit-managed dispatcher (force, or stopping the last
        # thinker), systemd notices the main PID exit and reaps the unit's
        # remaining processes itself — unit state converges on its own.
        proc = run_cli(_wrap("thinkers", *args), identity_env(identity, root), root)
    _raise_for_failure(proc)
    return _result("stop", names, proc)


def thinkers_step(root: Path, identity: IdentityInfo, name: str) -> dict:
    """Fire-and-forget manual trigger: cmd_step tees output to run/logs/<name>.log
    and may run for minutes (it can call an LLM), so don't block the request."""
    subprocess.Popen(
        _wrap("thinkers", "step", name),
        env=identity_env(identity, root),
        cwd=str(root),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    return {"ok": True, "action": "step", "names": [name]}


def llm_probe(root: Path) -> dict:
    """One tiny real LLM call through the same .env the thinkers use —
    answers 'is the provider healthy right now'. LLM_RETRIES=0 so the raw
    outcome isn't masked by llm's transient-retry logic."""
    model = ""
    for key, value in envfile.parse_env_file(root / ".env"):
        if key == "SHELLM_MODEL":
            model = value
    model = model or os.environ.get("SHELLM_MODEL", "")

    env = os.environ.copy()
    env["PATH"] = f"{BIN_DIR}:{TOOLS_DIR}:{env.get('PATH', '')}"
    env["SHELLM_WEB_SERVE_ROOT"] = str(root)
    env["LLM_RETRIES"] = "0"
    args = ["--no-stream", "--raw", "-t", "60"]
    if model:
        args.extend(["-m", model])
    args.append("ping")

    start = time.monotonic()
    proc = run_cli(_wrap("llm", *args), env, root, timeout=45)
    latency_ms = int((time.monotonic() - start) * 1000)

    if proc.returncode != 0:
        stderr_lines = [l for l in (proc.stderr or "").splitlines() if l.strip()]
        return {
            "ok": False,
            "latency_ms": latency_ms,
            "model": model or None,
            "error": stderr_lines[-1] if stderr_lines else f"exit {proc.returncode}",
        }
    provider = None
    try:
        provider = json.loads(proc.stdout).get("provider")
    except ValueError:
        pass
    return {
        "ok": True,
        "latency_ms": latency_ms,
        "model": model or None,
        "provider": provider,
    }


# The usage page polls the spend limit; a few seconds' staleness is fine.
_SPEND_TTL_S = 10
_spend_cache: dict[str, tuple[float, dict]] = {}


def llm_spend(root: Path, identity: IdentityInfo) -> dict:
    """The identity's spend limit as its own llm calls see it: `llm --spend`
    in the env the dash starts its thinkers with, so the numbers are bin/llm's
    arithmetic, not a second copy of it. No model call is made: llm reads the
    ledger lines appended since its last check. ok is false when llm rejects
    the limit's settings, which also stops every call it would make."""
    key = str(identity.path)
    hit = _spend_cache.get(key)
    if hit and time.monotonic() - hit[0] < _SPEND_TTL_S:
        return hit[1]
    proc = run_cli(_wrap("llm", "--spend"), identity_env(identity, root), root, timeout=15)
    stderr_lines = [l for l in (proc.stderr or "").splitlines() if l.strip()]
    result: dict = {"ok": False, "error": stderr_lines[-1] if stderr_lines else f"exit {proc.returncode}"}
    if proc.returncode == 0:
        try:
            spend = json.loads(proc.stdout)
            result = {"ok": True, **{k: spend.get(k) for k in ("spent", "limit", "remaining", "window", "since")}}
        except (ValueError, AttributeError):
            result = {"ok": False, "error": "llm --spend printed no JSON"}
    _spend_cache[key] = (time.monotonic(), result)
    return result


def recap_refresh(root: Path, identity: IdentityInfo, rebuild: bool = False) -> dict:
    """Fire-and-forget: recap makes one LLM call per window and can run for
    minutes; its own .lock serializes concurrent refreshes."""
    args = ["-q"] + (["--rebuild"] if rebuild else [])
    subprocess.Popen(
        _wrap("recap", *args),
        env=identity_env(identity, root),
        cwd=str(root),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    return {"ok": True, "action": "recap-refresh", "rebuild": rebuild}


def chat_send(
    root: Path,
    identity: IdentityInfo,
    content: str,
    from_name: str,
    source_url: str | None = None,
) -> dict:
    env = identity_env(identity, root)
    to_name = env["IDENTITY_NAME"]
    args = ["chat", "send", "--from", from_name, "--to", to_name]
    if source_url is not None:
        args.extend(["--source-url", source_url])
    proc = run_cli(
        _wrap(*args),
        env,
        root,
        stdin_text=content,
    )
    _raise_for_failure(proc)
    return {"ok": True, "from": from_name, "to": to_name}


def identity_new(root: Path, name: str) -> dict:
    proc = run_cli(
        [str(TOOLS_DIR / "identity"), "new", name], _identities_root_env(root), root
    )
    _raise_for_failure(proc)
    return {
        "ok": True,
        "id": f".identities~{name}",
        "name": name,
        "stderr": proc.stderr,
    }


def _identities_root_env(root: Path) -> dict[str, str]:
    """Env for identity-CLI calls that operate on the serve root's .identities
    (same shape as identity_new builds inline)."""
    env = os.environ.copy()
    env["PATH"] = f"{BIN_DIR}:{TOOLS_DIR}:{env.get('PATH', '')}"
    env["IDENTITY_DIR"] = str(root / ".identities")
    # With IDENTITY_NAME set, tools/identity treats IDENTITY_DIR as an active
    # identity and rebases to its parent — make sure we pass the root form.
    env.pop("IDENTITY_NAME", None)
    return env


def _export_to_tempfile(root: Path, args: list[str], env: dict[str, str]) -> Path:
    fd, tmp = tempfile.mkstemp(suffix=".shellm.tgz")
    os.close(fd)
    proc = run_cli(
        [str(TOOLS_DIR / "identity"), "export", *args, "-o", tmp],
        env,
        root,
        timeout=EXPORT_IMPORT_TIMEOUT,
    )
    if proc.returncode != 0:
        Path(tmp).unlink(missing_ok=True)
    _raise_for_failure(proc)
    return Path(tmp)


def identity_export(
    root: Path, identity: IdentityInfo, soul_only: bool = False, slim: bool = False
) -> Path:
    """Export one identity (any discovered dir, via --path) to a temp .tgz.
    Caller owns the returned file and must delete it. `slim` truncates the
    repeated shellm-run/prompt fields and redacts API keys (see
    `identity export --slim`); a 1GB mind log comes out around 17MB."""
    args = ["--path", str(identity.path)]
    if soul_only:
        args.append("--soul-only")
    if slim:
        args.append("--slim")
    return _export_to_tempfile(root, args, _identities_root_env(root))


def identity_export_all(root: Path, soul_only: bool = False) -> Path:
    """Export every identity under the serve root's .identities to a temp .tgz."""
    args = ["--all"]
    if soul_only:
        args.append("--soul-only")
    return _export_to_tempfile(root, args, _identities_root_env(root))


def identity_import(root: Path, archive: Path, name: str | None = None) -> dict:
    args = ["import", str(archive)]
    if name:
        args.extend(["--name", name])
    proc = run_cli(
        [str(TOOLS_DIR / "identity"), *args],
        _identities_root_env(root),
        root,
        timeout=EXPORT_IMPORT_TIMEOUT,
    )
    _raise_for_failure(proc)
    imported = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    return {
        "ok": True,
        "imported": [
            {"id": f".identities~{n}", "name": n} for n in imported
        ],
        "stderr": proc.stderr,
    }


def killall(dry_run: bool = False) -> dict:
    env = os.environ.copy()
    env["PATH"] = f"{BIN_DIR}:{TOOLS_DIR}:{env.get('PATH', '')}"
    args = [str(TOOLS_DIR / "headlong-killall")] + (["--dry-run"] if dry_run else [])
    proc = run_cli(args, env, BIN_DIR.parent)
    _raise_for_failure(proc)
    return {"ok": True, "dry_run": dry_run, "stdout": proc.stdout, "stderr": proc.stderr}
