"""Linux PTY regression: keep the terminal session alive after the TUI exits."""

import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time

repo = Path(__file__).resolve().parents[3]
binary = repo / 'tui/headlong/target/debug/headlong-tui'
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    shim = root / 'shim'
    shim.mkdir()
    trajectory_id = 'cafe0000-0000-0000-0000-0000000000ce'
    trajectory = root / 'trajectories' / trajectory_id
    trajectory.mkdir(parents=True)
    (trajectory / 'trajectory.jsonl').write_text(json.dumps({'step_id': 'header', 'type': 'trajectory'}) + '\n')
    marker = root / 'tail.pid'
    tail = shim / 'tail'
    tail.write_text('#!/bin/bash\nfor arg in "$@"; do\nif [[ "$arg" == "-F" ]]; then echo $$ > "$TAIL_PID_FILE"; fi\ndone\nexec /usr/bin/tail "$@"\n')
    tail.chmod(0o755)
    environment = dict(os.environ, PATH=f'{shim}:{repo / "bin"}:' + os.environ['PATH'],
                       TERM='xterm', TRAJ_DIR=str(root / 'trajectories'),
                       TRAJ_ID=trajectory_id, ROOT_TRAJ_ID=trajectory_id,
                       IDENTITY_NAME='fixture', TAIL_PID_FILE=str(marker))
    child, master = pty.fork()
    if child == 0:
        result = subprocess.run([str(binary)], env=environment)
        (root / 'tui.exit').write_text(str(result.returncode))
        time.sleep(10)
        os._exit(0)
    follower = None
    try:
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not marker.exists():
            if select.select([master], [], [], .05)[0]:
                os.read(master, 65536)
        assert marker.exists(), 'actual trajectory follower did not start'
        follower = int(marker.read_text())
        os.write(master, b'\x04')
        deadline = time.monotonic() + 5
        status = None
        while time.monotonic() < deadline:
            if (root / 'tui.exit').exists():
                status = int((root / 'tui.exit').read_text())
                break
            if select.select([master], [], [], .05)[0]:
                try:
                    os.read(master, 65536)
                except OSError:
                    pass
        assert status is not None, 'TUI did not exit after Ctrl+D'
        deadline = time.monotonic() + 2
        alive = True
        while alive and time.monotonic() < deadline:
            try:
                os.kill(follower, 0)
                state = Path(f'/proc/{follower}/stat').read_text().split(') ')[1].split()[0]
                alive = state != 'Z'
            except (ProcessLookupError, FileNotFoundError):
                alive = False
            if alive:
                time.sleep(.02)
        print(f'TUI_STATUS={status} TAIL_PID={follower} TAIL_ALIVE={alive}')
        assert status == 0, "TUI exit failed"
        assert not alive, "trajectory tail subprocess survived TUI shutdown"
    finally:
        if child is not None:
            os.kill(child, signal.SIGKILL)
            os.waitpid(child, 0)
        if follower is not None:
            try:
                os.kill(follower, signal.SIGKILL)
            except ProcessLookupError:
                pass
        os.close(master)
