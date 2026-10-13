#!/usr/bin/env python3
"""Install root-owned /usr/local/libexec/custos-backend-probe on Johan.

Bind a dedicated SSH public key in user@johan authorized_keys to:
restrict,from="192.168.86.44",command="/usr/bin/python3 /usr/local/libexec/custos-backend-probe" ssh-ed25519 ...
The key grants ONLY this read-only socket snapshot, never a guest shell. No
inference requests, process mutations, credentials, or model content are read.

An established gateway connection from .44 is our request. ALL other peer
addresses are foreign (including local health checks). Other blink1 clients
using .44 are indistinguishable: deploy them through a distinct source IP or the
same arbiter. Socket observations are not engine-idle proof: disconnected work
may briefly drain; cancellation is cooperative, never hard GPU preemption.
"""
import ipaddress
import json
from pathlib import Path
import socket
import sys


def address(encoded, ipv6):
    raw = bytes.fromhex(encoded)
    # Linux proc prints each native-endian u32 as eight hexadecimal digits.
    if sys.byteorder == "little":
        raw = b"".join(raw[i:i + 4][::-1] for i in range(0, len(raw), 4))
    result = ipaddress.ip_address(socket.inet_ntop(socket.AF_INET6 if ipv6 else socket.AF_INET, raw))
    return str(result.ipv4_mapped or result) if ipv6 else str(result)


def snapshot(paths=("/proc/net/tcp", "/proc/net/tcp6")):
    if socket.gethostname().split(".")[0] != "johan":
        raise RuntimeError("probe installed on wrong host")
    active, foreign = 0, 0
    listening = False
    for filename in paths:
        with Path(filename).open() as source:
            next(source)
            for line in source:
                fields = line.split()
                local, peer, state = fields[1:4]
                if int(local.rsplit(":", 1)[1], 16) != 8080:
                    continue
                if state == "0A":
                    listening = True
                if state in {"0A", "06", "07"}:  # listen, time_wait, close
                    continue
                active += 1
                foreign += address(peer.rsplit(":", 1)[0], filename.endswith("tcp6")) != "192.168.86.44"
    # A reachable SSH server is not a reachable inference server. Publishing a
    # fresh "busy" observation without a listener makes the gateway wait until
    # its deadline forever, preventing its existing unavailable-backend fallback.
    # Exit nonzero through main's existing handler so the observer publishes its
    # unavailable sentinel. Genuine socket contention still waits for Johan.
    if not listening:
        raise RuntimeError("inference listener unavailable")
    return {"foreign_busy": bool(foreign), "backend_idle": active == 0}


if __name__ == "__main__":
    try:
        print(json.dumps(snapshot(), separators=(",", ":")))
    except (OSError, ValueError, IndexError, StopIteration, RuntimeError):
        # Nonzero exit; producer writes an unavailable/stale observation.
        sys.exit(1)
