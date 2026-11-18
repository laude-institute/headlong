#!/usr/bin/env bash
# tests/test_chat_index_typeguard.sh — the messages-index writer type guard.
# The writer's select checked non-empty from/to, never their types, so a
# hand-built message step with a numeric `to` (only reachable via stdin
# `traj append`: every chat writer builds `to` with jq --arg, always a
# string) landed in messages.jsonl and every downstream whole-list reader
# aborted on it: `chat sent` died rc 5 on `test()` of a number, and
# `_refuse_key` read that abort as no-hit, passing a same-key reworded
# duplicate send. The guard: the writer accepts a row only when from and
# to are strings. (jq upstream sweep 2026-10-08, probeE.)
set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID CHAT_REPEAT_WINDOW 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

command -v jq >/dev/null 2>&1 || { echo 'FAIL jq not found'; exit 1; }

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT

ME=ada
ID="$WORK/ident"
TRAJ_ID="cafe1111-0000-0000-0000-0000000000cf"
mkdir -p "$ID/trajectories/$TRAJ_ID"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"
IDX="$ID/trajectories/$TRAJ_ID/messages.jsonl"
export IDENTITY_NAME="$ME" TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID"
export ROOT_TRAJ_ID="$TRAJ_ID"
export HOME="$WORK/home"; mkdir -p "$HOME"
printf 'default_send_from=%s\n' "$ME" > "$HOME/.chatrc"
export CHATRC="$HOME/.chatrc"

ago() {
    date -u -d "$1 seconds ago" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
        || date -u -v-"$1"S +%Y-%m-%dT%H:%M:%S.000Z
}

printf '{"step_id":"%s","type":"trajectory","ts":"%s"}\n' "$TRAJ_ID" "$(ago 999999)" > "$TRAJ"

# The planted row: numeric `to` through the operator-shaped path.
printf '%s' '{"type":"message","source":"monolith","step_id":"zz4","ts":"2026-10-08T13:06:00Z","from":"ada","to":123,"content":"numeric to row"}' \
    | traj append --traj_dir "$ID/trajectories" "$TRAJ_ID" >/dev/null

# Any chat read builds the index.
chat sent --since 24h -n 10 >/dev/null 2>&1

# a1: the writer drops the numeric-to row.
if ! grep -q '"to":123' "$IDX" 2>/dev/null; then
    ok 'writer drops a message step with numeric to'
else
    bad 'writer drops a message step with numeric to' "row in index: $(grep '"to":123' "$IDX")"
fi

# a2: the writer keeps a control row's string to intact.
printf '%s' '{"type":"message","source":"monolith","step_id":"zz5","ts":"2026-10-08T13:07:00Z","from":"ada","to":"probe-you","content":"good row"}' \
    | traj append --traj_dir "$ID/trajectories" "$TRAJ_ID" >/dev/null
chat sent --since 24h -n 10 >/dev/null 2>&1
if grep -q '"to":"probe-you"' "$IDX" 2>/dev/null; then
    ok 'writer keeps string to rows'
else
    bad 'writer keeps string to rows' 'control row missing from index'
fi

# a3: `chat sent` reads the whole list with the planted step present.
sent_rc=0
chat sent --since 24h -n 10 >/dev/null 2>&1 || sent_rc=$?
if [[ "$sent_rc" -eq 0 ]]; then
    ok 'chat sent reads the whole list over a planted numeric-to step'
else
    bad 'chat sent reads the whole list over a planted numeric-to step' "rc=$sent_rc"
fi

# a4: `chat history` (indexed path) reads the whole list too.
hist_rc=0
chat history --with probe-you -n 5 >/dev/null 2>&1 || hist_rc=$?
if [[ "$hist_rc" -eq 0 ]]; then
    ok 'chat history reads the whole list over a planted numeric-to step'
else
    bad 'chat history reads the whole list over a planted numeric-to step' "rc=$hist_rc"
fi

# a5: the keyed-send guard does not fail open: a same-key reworded
# duplicate is refused while the corrupt row is in the index.
echo 'first keyed send into a corrupt index' \
    | chat send --to probe-you --key k1 >/dev/null 2>&1
send1_rc=$?
echo 'reworded duplicate, same key, corrupt index present' \
    | chat send --to probe-you --key k1 >/dev/null 2>&1
send2_rc=$?
if [[ "$send1_rc" -eq 0 && "$send2_rc" -ne 0 ]]; then
    ok 'keyed duplicate refused over a planted numeric-to step'
else
    bad 'keyed duplicate refused over a planted numeric-to step' "send1=$send1_rc send2=$send2_rc"
fi

# a6: the exact-text repeat check still fires over the planted row.
echo 'first keyed send into a corrupt index' \
    | chat send --to probe-you >/dev/null 2>&1
send3_rc=$?
if [[ "$send3_rc" -ne 0 ]]; then
    ok 'exact-text repeat check still refuses over a planted numeric-to step'
else
    bad 'exact-text repeat check still refuses over a planted numeric-to step' 'duplicate passed'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
