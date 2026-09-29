#!/usr/bin/env bash
# test_monolith_request_model.sh — the monolith's two model tiers: with
# MONOLITH_REQUEST_MODEL set, a reactive wake or a wake with an open pending
# request runs on that model; a spontaneous timer wake with nothing pending
# stays on SHELLM_MODEL; unset, every wake uses SHELLM_MODEL.
#
# Usage: tests/test_monolith_request_model.sh
#
# Drives thinkers/monolith/step against a throwaway identity with a stubbed
# `shellm` (records its --model argument, appends nothing) and a stubbed
# `chat` (answers `chat pending --json` from a file, so the pending-request
# path needs no deferrals index). No LLM calls, no dispatcher.

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
TRAJ_ID="cafe0000-0000-0000-0000-0000000000bb"
mkdir -p "$ID/memories" "$ID/trajectories/$TRAJ_ID" "$ID/run"
printf 'name=testid\ncreated=test\nroot_trajectory=%s\n' "$TRAJ_ID" > "$ID/info.txt"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"
: > "$TRAJ"
printf 'test-token\n' > "$ID/run/dispatcher.token"   # arm_wake requires it

# --- stubs -------------------------------------------------------------------
mkdir -p "$WORK/stub"
# shellm: record the --model argument and the prompt, append nothing.
cat > "$WORK/stub/shellm" <<'STUB'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
    [[ "$prev" == "--model" ]] && printf '%s\n' "$a" >> "$STUB_MODELS"
    [[ "$prev" == "--prompt-file" ]] && cp "$a" "$STUB_CAPTURE"
    prev="$a"
done
printf '%s\n' "${SHELLM_WAKE:-}" >> "$STUB_WAKES"
exit 0
STUB
# chat: `pending --json` prints the canned list; anything else is a no-op.
cat > "$WORK/stub/chat" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "pending" ]]; then
    cat "$STUB_PENDING" 2>/dev/null || printf '[]'
fi
exit 0
STUB
chmod +x "$WORK/stub/shellm" "$WORK/stub/chat"

export STUB_MODELS="$WORK/models"
export STUB_WAKES="$WORK/wakes"
export STUB_CAPTURE="$WORK/prompt-captured"
export STUB_PENDING="$WORK/pending.json"
export SHELLM_MODEL="cheap-model"

run_step() {  # $1 = trigger json; extra env as VAR=VAL args after it
    printf '%s' "$1" | env \
        PATH="$WORK/stub:$REPO/bin:$PATH" \
        IDENTITY_DIR="$ID" IDENTITY_NAME=testid MEM_DIR="$ID/memories" \
        TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID" HOME="$WORK/home" \
        MONOLITH_TIERED_MEMORY=0 MONOLITH_SHARE_HINT_EVERY=0 \
        MONOLITH_IDLE_FASTPATH=0 \
        "${@:2}" "$STEP" >> "$WORK/step.log" 2>&1
}
WAKE='{"type":"monolith-wake","content":"wake","source":"monolith-timer"}'
REACTIVE='{"type":"observation","step_id":"ext-1","content":"external event","source":"responder"}'
PENDING='[{"trigger_step":"m-1","person":"nick","request":"find the paper","age_s":120}]'

model_used() { tail -n 1 "$STUB_MODELS" 2>/dev/null; }
reset_state() {
    rm -f "$ID/run/monolith_backoff_state.json" "$ID/run/monolith.wake_at" \
          "$STUB_MODELS" "$STUB_WAKES" "$STUB_CAPTURE" "$STUB_PENDING"
    : > "$TRAJ"; : > "$WORK/step.log"
}

# --- 1. no request model: every wake runs on SHELLM_MODEL --------------------
reset_state
run_step "$WAKE"
m1=$(model_used)
run_step "$REACTIVE"
m2=$(model_used)
printf '%s' "$PENDING" > "$STUB_PENDING"
run_step "$WAKE"
m3=$(model_used)
if [[ "$m1" == cheap-model && "$m2" == cheap-model && "$m3" == cheap-model ]]; then
    ok "MONOLITH_REQUEST_MODEL unset: timer, reactive and pending wakes all use SHELLM_MODEL"
else
    bad "MONOLITH_REQUEST_MODEL unset: every wake uses SHELLM_MODEL" "got $m1,$m2,$m3"
fi

# --- 2. spontaneous wake, nothing pending: cheap tier -------------------------
reset_state
run_step "$WAKE" MONOLITH_REQUEST_MODEL=big-model
if [[ "$(model_used)" == cheap-model ]]; then
    ok "timer wake with nothing pending stays on SHELLM_MODEL"
else
    bad "timer wake with nothing pending stays on SHELLM_MODEL" "got $(model_used)"
fi
if grep -q 'model cheap-model (think tier)' "$WORK/step.log"; then
    ok "step log names the think tier"
else
    bad "step log names the think tier"
fi

# --- 3. reactive wake: request tier ------------------------------------------
reset_state
run_step "$REACTIVE" MONOLITH_REQUEST_MODEL=big-model
if [[ "$(model_used)" == big-model ]]; then
    ok "reactive wake runs on MONOLITH_REQUEST_MODEL"
else
    bad "reactive wake runs on MONOLITH_REQUEST_MODEL" "got $(model_used)"
fi
if grep -q 'model big-model (request tier)' "$WORK/step.log"; then
    ok "step log names the request tier"
else
    bad "step log names the request tier"
fi

# --- 4. timer wake with an open pending request: request tier ----------------
reset_state
printf '%s' "$PENDING" > "$STUB_PENDING"
run_step "$WAKE" MONOLITH_REQUEST_MODEL=big-model
if [[ "$(model_used)" == big-model ]]; then
    ok "timer wake with a pending request runs on MONOLITH_REQUEST_MODEL"
else
    bad "timer wake with a pending request runs on MONOLITH_REQUEST_MODEL" "got $(model_used)"
fi
if grep -q 'PENDING REQUEST from nick' "$STUB_CAPTURE" 2>/dev/null; then
    ok "the pending request is in the prompt of that wake"
else
    bad "the pending request is in the prompt of that wake"
fi

# --- 5. the request resolved: the next timer wake drops back to cheap --------
printf '[]' > "$STUB_PENDING"
run_step "$WAKE" MONOLITH_REQUEST_MODEL=big-model
if [[ "$(model_used)" == cheap-model ]]; then
    ok "once nothing is pending, the timer wake is back on SHELLM_MODEL"
else
    bad "once nothing is pending, the timer wake is back on SHELLM_MODEL" "got $(model_used)"
fi

# --- 6. the request tier is stamped on the run's wake reason -----------------
reset_state
run_step "$REACTIVE" MONOLITH_REQUEST_MODEL=big-model
w1=$(tail -n 1 "$STUB_WAKES" 2>/dev/null)
printf '[]' > "$STUB_PENDING"
run_step "$WAKE" MONOLITH_REQUEST_MODEL=big-model
w2=$(tail -n 1 "$STUB_WAKES" 2>/dev/null)
if [[ "$w1" == "reactive/observation:responder/request" && "$w2" == "spontaneous/timer" ]]; then
    ok "wake reason carries the tier only on request wakes"
else
    bad "wake reason carries the tier only on request wakes" "got '$w1' then '$w2'"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
