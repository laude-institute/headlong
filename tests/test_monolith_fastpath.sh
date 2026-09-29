#!/usr/bin/env bash
# test_monolith_fastpath.sh — monolith backoff: visible work vs thought-only,
# the thought cap, the error descent, and the share nudge.
#
# Usage: tests/test_monolith_backoff.sh
#
# Drives thinkers/monolith/step directly against a throwaway identity with a
# stubbed `shellm` on PATH. The stub reads $STUB_MODE and appends an
# observation ("obs"), a thought ("thought"), nothing ("none"), or exits
# non-zero ("fail") — and captures the --prompt-file contents so the share
# nudge can be asserted. No LLM calls, no docker, no dispatcher: the step's
# own state file (monolith_backoff_state.json) and wake_at file are the
# observable outputs. Small BASE/CAP/HOLD values keep the math readable:
#   BASE=5 FACTOR=2 CAP=40 HOLD=1 THOUGHT_CAP=7
#   delay(level): 0, 5, 10, 20, 40, 40, ...

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
STEP="$REPO/thinkers/monolith/step"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT

ID="$WORK/ident"
TRAJ_ID="cafe0000-0000-0000-0000-0000000000ba"
mkdir -p "$ID/memories" "$ID/trajectories/$TRAJ_ID" "$ID/run"
printf 'name=testid\ncreated=test\nroot_trajectory=%s\n' "$TRAJ_ID" > "$ID/info.txt"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"
: > "$TRAJ"
printf 'test-token\n' > "$ID/run/dispatcher.token"   # arm_wake requires it

# --- shellm stub -------------------------------------------------------------
# Appends a step to the trajectory per $STUB_MODE and captures the prompt.
mkdir -p "$WORK/stub"
cat > "$WORK/stub/shellm" <<'STUB'
#!/usr/bin/env bash
echo call >> "$STUB_CALLS"
prev=""
for a in "$@"; do
    [[ "$prev" == "--prompt-file" ]] && cp "$a" "$STUB_CAPTURE"
    prev="$a"
done
mode=$(cat "$STUB_MODE_FILE" 2>/dev/null || echo none)
n=$RANDOM$RANDOM
printf '{"type":"shellm-run","step_id":"r-%s"}\n{"type":"reasoning","step_id":"q-%s"}\n{"type":"final","step_id":"f-%s","content":"Idle"}\n' "$n" "$n" "$n" >> "$STUB_TRAJ"
case "$mode" in
    obs)     printf '{"type":"observation","step_id":"o-%s","content":"did a thing","source":"monolith"}\n' "$n" >> "$STUB_TRAJ" ;;
    thought) printf '{"type":"thought","step_id":"t-%s","content":"nothing changed","source":"monolith"}\n' "$n" >> "$STUB_TRAJ" ;;
    fail)    exit 3 ;;
    fail-diag) printf 'diag-run-0001' > "$SHELLM_RUN_ID_OUT"
               printf '{"type":"shell-output","step_id":"diag-so-1","run_id":"diag-run-0001","stdout":"boom: the actual diagnostic","exit":1,"source":"monolith"}\n' >> "$STUB_TRAJ"
               printf '{"type":"shell-output","step_id":"diag-so-2","run_id":"diag-run-0001","stdout":"=== me === benign status read after the failure","exit":0,"source":"monolith"}\n' >> "$STUB_TRAJ"
               exit 3 ;;
    fail-diag-noexit) printf 'diag-run-0002' > "$SHELLM_RUN_ID_OUT"
               printf '{"type":"shell-output","step_id":"diag-so-3","run_id":"diag-run-0002","stdout":"hang then killed, no exit code recorded","source":"monolith"}\n' >> "$STUB_TRAJ"
               exit 3 ;;
    none)    : ;;
esac
exit 0
STUB
chmod +x "$WORK/stub/shellm"

export STUB_CALLS="$WORK/calls"
export STUB_MODE_FILE="$WORK/mode"
export STUB_TRAJ="$TRAJ"
export STUB_CAPTURE="$WORK/prompt-captured"
export SHELLM_MODEL="test-model"

STATE="$ID/run/monolith_backoff_state.json"
WAKE_AT="$ID/run/monolith.wake_at"

run_step() {  # $1 = trigger json
    printf '%s' "$1" | env \
        PATH="$WORK/stub:$REPO/bin:$PATH" \
        IDENTITY_DIR="$ID" IDENTITY_NAME=testid MEM_DIR="$ID/memories" \
        TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID" HOME="$WORK/home" \
        MONOLITH_TIERED_MEMORY=0 \
        MONOLITH_IDLE_FASTPATH=1 \
        MONOLITH_BACKOFF_BASE=5 MONOLITH_BACKOFF_FACTOR=2 \
        MONOLITH_BACKOFF_CAP=1800 MONOLITH_BACKOFF_HOLD=1 \
        MONOLITH_THOUGHT_CAP=7 MONOLITH_SHARE_HINT_EVERY="${SHARE_EVERY:-0}" \
        "$STEP" >> "$WORK/step.log" 2>&1
}
WAKE='{"type":"monolith-wake","content":"wake","source":"monolith-timer"}'
REACTIVE='{"type":"observation","step_id":"ext-1","content":"external event","source":"tester"}'

delay() {  # wake_at minus now (integer seconds; "-" if no file)
    [[ -f "$WAKE_AT" ]] || { echo "-"; return; }
    echo $(( $(cat "$WAKE_AT") - $(date +%s) ))
}
lvl()  { jq -r .level "$STATE" 2>/dev/null; }
near() { local v="$1" want="$2"; [[ "$v" -ge $((want-1)) && "$v" -le $((want+1)) ]]; }
reset_state() { rm -f "$STATE" "$WAKE_AT" "$STUB_CAPTURE"; : > "$TRAJ"; : > "$WORK/step.log"; }


FAST="$ID/run/monolith_fastpath.json"
calls() { wc -l < "$STUB_CALLS" | tr -d ' '; }
check_call() {
    local before=$(calls)
    run_step "$WAKE"
    if [[ $(calls) -eq $((before + 1)) ]]; then ok "$1"; else bad "$1"; fi
}
# Seed a real row, as bootstrap with no readable log must fail open.
printf '{"type":"thought","step_id":"seed","content":"seed","source":"monolith"}\n' >> "$TRAJ"
echo none > "$STUB_MODE_FILE"
: > "$STUB_CALLS"
check_call "cold start runs fully"
before=$(calls)
run_step "$WAKE"
if [[ $(calls) -eq "$before" ]] && jq -e 'select(.model_skipped == true)' "$TRAJ" >/dev/null; then
    ok "unchanged idle timer skips with explicit trajectory marker"
else bad "unchanged idle timer skips with explicit trajectory marker"; fi
before=$(calls)
run_step "$WAKE"
[[ $(calls) -eq "$before" ]] && ok "skip does not invalidate successor" || bad "skip does not invalidate successor"
# Floor boundary: use persisted start, no wall-clock sleep.
jq --argjson now "$(date +%s)" '.last_full = ($now - 900)' "$FAST" > "$WORK/tmp"
mv "$WORK/tmp" "$FAST"
check_call "900 second boundary forces full turn"
jq --argjson now "$(date +%s)" '.last_full = ($now + 3600)' "$FAST" > "$WORK/tmp"
mv "$WORK/tmp" "$FAST"
check_call "clock regression fails open"
printf '{broken\n' > "$FAST"
check_call "corrupt cache fails open"
# Manual triggers are not timer checks, even with identical state.
before=$(calls); run_step '{"type":"manual-trigger","source":"operator"}'
[[ $(calls) -eq $((before + 1)) ]] && ok "manual bypass" || bad "manual bypass"
printf '{"type":"new-unknown-event","step_id":"unknown1"}\n' >> "$TRAJ"
check_call "unknown event invalidates signature"
printf '{broken raw row\n' >> "$TRAJ"
check_call "malformed raw tail fails open"
check_call "persistent malformed raw tail never skips"
# Drop only the deliberately malformed fixture from this temporary test log.
grep -v '^{broken raw row$' "$TRAJ" > "$WORK/tmp"; mv "$WORK/tmp" "$TRAJ"
check_call "recovery from malformed tail runs fully"

before=$(calls); run_step "$REACTIVE"
[[ $(calls) -eq $((before + 1)) ]] && ok "reactive bypass" || bad "reactive bypass"
printf '{"type":"message","step_id":"inbound","from":"human","to":"testid","content":"hi"}\n' >> "$TRAJ"
check_call "inbound invalidates signature"
printf '{"type":"delivery","step_id":"delivery1","status":"failed"}\n' >> "$TRAJ"
check_call "delivery invalidates signature"
cat > "$ID/memories/example.md" <<'MEM'
---
type: goal
summary: test
---
Remember something
MEM
check_call "memory content invalidates signature"
printf 'Changed content\n' >> "$ID/memories/example.md"
check_call "memory edit invalidates signature"
# Pending stub delegates all other operations to the scratch repository tool.
cat > "$WORK/stub/chat" <<'CHAT'
#!/usr/bin/env bash
if [[ "$1" == pending ]]; then
    if [[ -f "$STUB_PENDING_FAIL" ]]; then exit 1; fi
    cat "$STUB_PENDING"
else
    exec "$STUB_REAL_CHAT" "$@"
fi
CHAT
chmod +x "$WORK/stub/chat"
export STUB_PENDING="$WORK/pending.json" STUB_PENDING_FAIL="$WORK/pending.fail"
export STUB_REAL_CHAT="$REPO/bin/chat"
printf '[{"trigger_step":"request1","person":"tester","request":"do work","age_s":1}]\n' > "$STUB_PENDING"
check_call "pending request forces turn"
check_call "unchanged pending request still forces turn"
echo '[ ]' > "$STUB_PENDING"
run_step "$WAKE"
before=$(calls); run_step "$WAKE"
[[ $(calls) -eq "$before" ]] && ok "whitespace empty pending array allows skip" || bad "whitespace empty pending array allows skip"
touch "$STUB_PENDING_FAIL"
check_call "pending probe failure fails open"
rm "$STUB_PENDING_FAIL"
echo thought > "$STUB_MODE_FILE"
check_call "post probe failure gets full turn"
check_call "thought output retains momentum"
echo obs > "$STUB_MODE_FILE"
check_call "visible output retains momentum"
check_call "continued visible output not skipped"
echo fail > "$STUB_MODE_FILE"
check_call "model failure runs"
check_call "model failure not cached as idle"
echo none > "$STUB_MODE_FILE"
check_call "recovery full turn"
# Scheduling signal must bypass even if its due window was already seen.
cat > "$ID/memories/scheduled.md" <<MEM
---
type: goal
id: scheduled-test
summary: test schedule
schedule: $(date -u +%H:%M)
tz: UTC
---
Do it
MEM
check_call "due scheduled goal runs"
check_call "unchanged due scheduled goal still runs"
rm "$ID/memories/scheduled.md"
check_call "schedule removal invalidates"
SHARE_EVERY=1
check_call "share nudge forces full turn"
unset SHARE_EVERY
check_call "config change invalidates"
# High backoff must not put the floor past 900s.
jq '.level=20' "$STATE" > "$WORK/tmp"; mv "$WORK/tmp" "$STATE"
jq --argjson now "$(date +%s)" '.last_full=($now - 895)' "$FAST" > "$WORK/tmp"
mv "$WORK/tmp" "$FAST"
run_step "$WAKE"
d=$(delay)
if [[ "$d" -ge 0 && "$d" -le 5 ]]; then ok "wake timer clamps to remaining floor"; else bad "wake timer clamps to remaining floor" "$d"; fi
printf '\n%d passed, %d failed\n' "$pass" "$fail"
if (( fail )); then tail -60 "$WORK/step.log"; fi
(( fail == 0 ))
