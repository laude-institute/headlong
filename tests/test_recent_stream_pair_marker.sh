#!/usr/bin/env bash
# tests/test_recent_stream_pair_marker.sh — the pair fold in the recent-stream
# filter marks what it folds.
#
# Pins: when a final arrives, the run's nearest earlier observation folds out
# of the stream and the final carries a `folded` field naming the folded
# observation's id with a traj show route (the be080b0 marker shape: what
# dropped plus the route to it); the final's `details` command stays plain and
# runnable, the marker living in its own field; a run with several
# observations folds only the last; a long id is cut to the 8-character prefix
# traj accepts; a final with no earlier observation carries no marker; an
# observation with no step id folds unmarked; the fold itself still happens;
# idle rows are untouched. The three marker arms are born red on eab04ad. No
# LLM calls, no docker.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID THINK_CONTEXT_TAIL 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

command -v jq >/dev/null 2>&1 || { echo "FAIL jq not found"; exit 1; }

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT

ID="$WORK/ident"
TRAJ_ID="cafe0000-0000-0000-0000000000ef"
mkdir -p "$ID/trajectories/$TRAJ_ID"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"
export IDENTITY_NAME=ada TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID" IDENTITY_DIR="$ID" MEM_DIR="$ID/memories"

ts() { python3 -c "import datetime as d; print((d.datetime(2026,9,2,12,0,tzinfo=d.timezone.utc)-d.timedelta(minutes=$1)).strftime('%Y-%m-%dT%H:%M:%S.000Z'))"; }
step() {
    printf '{"step_id":"%s","type":"%s","content":%s,"ts":"%s","source":"monolith"%s}\n' \
        "$1" "$2" "$(printf '%s' "$3" | jq -Rsa .)" "$(ts "$4")" "${5:-}" >> "$TRAJ"
}
stream() {
    (
        # shellcheck disable=SC1091
        source "$REPO/thinkers/_lib/common.sh"
        _recent_stream "$1"
    )
}

: > "$TRAJ"
printf '{"step_id":"hdr","type":"trajectory","ts":"%s"}\n' "$(ts 9999)" >> "$TRAJ"
step a1  thought     "thought a"                       300 ',"run_id":"run-0a"'
step ao1 observation  "milestone one"                   299 ',"run_id":"run-0a"'
step ao2 observation  "milestone two, the last one"     298 ',"run_id":"run-0a"'
step af1 final        "run a concluded"                 297 ',"run_id":"run-0a"'
step bf1 final        "run b concluded, no observation" 250 ',"run_id":"run-0b"'
step co1 observation  "the correction lives here"      200 ',"run_id":"run-0c"'
step cf1 final        "run c concluded"                 199 ',"run_id":"run-0c"'
step ""  observation "no id observation"               150 ',"run_id":"run-0d"'
step df1 final        "run d concluded"                 149 ',"run_id":"run-0d"'
step "aaaa1111-bbbb-cccc-dddd-eeeeffff0000" observation "uuid milestone" 120 ',"run_id":"run-0e"'
step ef1 final        "run e concluded"                 119 ',"run_id":"run-0e"'
step i1  idle idle 90
step i2  idle idle 80

out=$(stream 40) || out=""
printf '%s\n' "$out" > "$WORK/out.jsonl"

# 1. the fold itself still happens
jq -s 'map(select(.type=="observation" and .step_id=="ao2")) | length == 0' "$WORK/out.jsonl" >/dev/null 2>&1 \
  && ok "the run's last observation folds out of the stream" \
  || bad "the run's last observation folds out of the stream"
# 2. earlier observation stays as a milestone
jq -s 'map(select(.type=="observation" and .step_id=="ao1")) | length == 1' "$WORK/out.jsonl" >/dev/null 2>&1 \
  && ok "an earlier observation stays as a milestone" \
  || bad "an earlier observation stays as a milestone"
# 3. the final carries a folded field naming the folded observation (red on base)
fa=$(jq -r 'select(.step_id=="af1") | .folded // "none"' "$WORK/out.jsonl")
[[ "$fa" == "observation ao2: traj show ao2" ]] \
  && ok "the final's folded field names the folded observation and its route" \
  || bad "the final's folded field names the folded observation and its route" "got: $fa"
# 4. the marker names the last observation only
[[ "$fa" != *"ao1"* ]] \
  && ok "the marker names the last observation, not an earlier milestone" \
  || bad "the marker names the last observation, not an earlier milestone" "got: $fa"
# 5. the details command stays plain and runnable
da=$(jq -r 'select(.step_id=="af1") | .details // "none"' "$WORK/out.jsonl")
[[ "$da" == "traj tail -n 400 --filter run_id=run-0a" ]] \
  && ok "the details command stays plain, the marker in its own field" \
  || bad "the details command stays plain, the marker in its own field" "got: $da"
# 6. each folded run carries its own marker (red on base)
fc=$(jq -r 'select(.step_id=="cf1") | .folded // "none"' "$WORK/out.jsonl")
[[ "$fc" == "observation co1: traj show co1" ]] \
  && ok "each run's final carries its own fold marker" \
  || bad "each run's final carries its own fold marker" "got: $fc"
# 7. a final with no earlier observation carries no marker
jq -e 'select(.step_id=="bf1") | has("folded") | not' "$WORK/out.jsonl" >/dev/null 2>&1 \
  && ok "a final with no earlier observation carries no marker" \
  || bad "a final with no earlier observation carries no marker"
# 8. an observation with no step id folds unmarked
jq -e 'select(.step_id=="df1") | has("folded") | not' "$WORK/out.jsonl" >/dev/null 2>&1 \
  && ok "an observation with no step id folds without a marker" \
  || bad "an observation with no step id folds without a marker"
# 9. a long id is cut to the 8-character prefix traj accepts (red on base)
fe=$(jq -r 'select(.step_id=="ef1") | .folded // "none"' "$WORK/out.jsonl")
[[ "$fe" == "observation aaaa1111: traj show aaaa1111" ]] \
  && ok "a long id is cut to the prefix traj show accepts" \
  || bad "a long id is cut to the prefix traj show accepts" "got: $fe"
# 10. idle rows still collapse, untouched by the marker
ni=$(jq -s 'map(select(.type=="idle")) | length' "$WORK/out.jsonl")
[[ "$ni" == "1" ]] \
  && ok "idle rows still collapse with no marker" \
  || bad "idle rows still collapse with no marker" "got: $ni idle lines"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
