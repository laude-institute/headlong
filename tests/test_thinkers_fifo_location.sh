#!/usr/bin/env bash
# test_thinkers_fifo_location.sh — the dispatcher fifo lives outside the identity
#
# Usage:
#   tests/test_thinkers_fifo_location.sh
#
# The mind walks its own identity dir, and anything that opens a fifo as a
# file blocks in read() forever while stealing step lines from the dispatcher
# (Audel 2026-09-25: a secret scan sat 3.5 h on run/dispatch.fifo). The
# dispatcher now makes its fifo under /tmp, records the path in run/fifo_path,
# and removes both on stop. Uses a fake thinker; no LLM calls. Runtime ~10s.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
PATH="$REPO/bin:$PATH"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/thinkers-fifo.XXXXXX") || exit 1
TRAJ_ID="cafe0000-0000-0000-0000-000000000009"
RUN="$TMP/id/run"
TRAJ="$TMP/id/trajectories/$TRAJ_ID/trajectory.jsonl"

env_run() {
    IDENTITY_DIR="$TMP/id" IDENTITY_NAME=testid \
    TRAJ_DIR="$TMP/id/trajectories" TRAJ_ID="$TRAJ_ID" \
    THINKERS_DIR="$TMP/id/thinkers" MEM_DIR="$TMP/id/memories" \
    "$@"
}

cleanup() {
    env_run thinkers stop >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/id/thinkers/recorder" "$TMP/id/trajectories/$TRAJ_ID" "$TMP/id/memories"
printf 'name=testid\ncreated=test\nroot_trajectory=%s\n' "$TRAJ_ID" > "$TMP/id/info.txt"
: > "$TRAJ"
cat > "$TMP/id/thinkers/recorder/step" <<'EOF'
#!/usr/bin/env bash
cat >> "$IDENTITY_DIR/record"
printf '\n' >> "$IDENTITY_DIR/record"
EOF
chmod +x "$TMP/id/thinkers/recorder/step"
printf '{"types":["action"],"trigger_self":false}\n' > "$TMP/id/thinkers/recorder/subscriptions.jsonl"

# A leftover from a dispatcher before the move must not survive a start.
mkdir -p "$RUN"
mkfifo "$RUN/dispatch.fifo"

env_run thinkers start >/dev/null 2>&1
sleep 2

fifo=$(head -n 1 "$RUN/fifo_path" 2>/dev/null || true)
case "$fifo" in
    /tmp/headlong-dispatch.*/dispatch.fifo)
        if [[ -p "$fifo" ]]; then ok "fifo_path names a fifo under /tmp"
        else bad "fifo_path names a fifo under /tmp" "not a fifo: $fifo"; fi ;;
    *) bad "fifo_path names a fifo under /tmp" "got '$fifo'" ;;
esac

inside=$(find "$TMP/id" -type p 2>/dev/null)
if [[ -z "$inside" ]]; then ok "no fifo inside the identity dir"
else bad "no fifo inside the identity dir" "$inside"; fi

# Steps still reach the thinker through the relocated fifo.
printf '%s\n' '{"type":"action","content":"ping-1","step_id":"s1"}' >> "$TRAJ"
for _ in $(seq 1 20); do
    grep -q 'ping-1' "$TMP/id/record" 2>/dev/null && break
    sleep 0.5
done
if grep -q 'ping-1' "$TMP/id/record" 2>/dev/null; then ok "a new step is dispatched"
else bad "a new step is dispatched"; fi

env_run thinkers stop >/dev/null 2>&1
if [[ ! -e "$fifo" && ! -e "${fifo%/dispatch.fifo}" && ! -e "$RUN/fifo_path" ]]; then
    ok "stop removes the fifo, its dir, and fifo_path"
else
    bad "stop removes the fifo, its dir, and fifo_path"
fi

# A crash skips the dispatcher's EXIT trap. Stop still owns the snapshotted
# FIFO and must remove it. Signal only the PID of this disposable fixture.
env_run thinkers start >/dev/null 2>&1
sleep 2
crashed_fifo=$(cat "$RUN/fifo_path")
fixture_pid=$(cat "$RUN/dispatcher.pid")
kill -KILL "$fixture_pid"
sleep 1
env_run thinkers stop >/dev/null 2>&1
if [[ ! -e "$crashed_fifo" && ! -e "${crashed_fifo%/dispatch.fifo}" ]]; then
    ok "stop removes a crashed owner's fifo and directory"
else bad "stop removes a crashed owner's fifo and directory"; fi

# Ownership loss must release only the old owner's FIFO. A successor's pointer
# and pending work are written after changing the token, just as a takeover does.
env_run thinkers start >/dev/null 2>&1
sleep 2
old_fifo=$(cat "$RUN/fifo_path")
mkfifo "$TMP/successor-fifo"
printf 'successor' > "$RUN/dispatcher.token"
printf '%s\n' "$TMP/successor-fifo" > "$RUN/fifo_path"
printf 'keep' > "$RUN/pending/successor"
# The old owner notices the token swap on its next heartbeat tick (the
# dispatch loop's 1s read timeout), so on a quiet machine its cleanup lands
# within a second or two. A loaded CI runner can starve that tick far past
# any fixed wait, which is how the macOS leg lost this race on PR 257
# (run 44241713411, attempt 1). Poll for the cleanup instead of guessing
# a sleep, bounded at 30s so a dead owner still fails the assertion
# instead of hanging the leg.
for _ in $(seq 1 60); do
    [[ -e "$old_fifo" || -e "${old_fifo%/dispatch.fifo}" ]] || break
    sleep 0.5
done
if [[ ! -e "$old_fifo" && ! -e "${old_fifo%/dispatch.fifo}" &&
      -p "$TMP/successor-fifo" && -f "$RUN/pending/successor" &&
      "$(cat "$RUN/fifo_path")" == "$TMP/successor-fifo" ]]; then
    ok "ownership loss removes only the old fifo, preserving successor state"
else bad "ownership loss removes only the old fifo, preserving successor state"; fi
env_run thinkers stop >/dev/null 2>&1

# A fifo_path the mind rewrote to point elsewhere is never followed.
decoy="$TMP/decoy"
mkfifo "$decoy"
printf '%s\n' "$decoy" > "$RUN/fifo_path"
env_run thinkers stop >/dev/null 2>&1
if [[ -p "$decoy" && ! -e "$RUN/fifo_path" ]]; then ok "a foreign fifo_path is ignored"
else bad "a foreign fifo_path is ignored"; fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
