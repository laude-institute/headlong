#!/usr/bin/env bash
# test_monolith_maxtime.sh — the wake run's LLM_MAX_TIME ceiling
#
# A monolith wake is one long generation: LLM_MAX_TOKENS licenses runs past
# bin/llm's 600s default, and the wrapper cannot retry a partial stream, so
# a mid-stream ceiling kill loses the whole wake (two production kills at
# healthy 8-11 KB/s rates, well above the 100 B/s stall floor). The step
# must therefore raise the ceiling at its shellm call site: 1800s like
# tools/pr-committee, a pre-set LLM_MAX_TIME still winning, an explicit 0
# (ceiling disabled) preserved, and an empty value treated as unset.
#
# Usage: tests/test_monolith_maxtime.sh
#
# Drives thinkers/monolith/step against a throwaway identity with a stubbed
# `shellm` on PATH that records the LLM_MAX_TIME it was invoked with. No LLM
# calls, no docker, no dispatcher.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID 2>/dev/null
unset LLM_MAX_TIME

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
TRAJ_ID="cafe0000-0000-0000-0000-000000000bc"
mkdir -p "$ID/memories" "$ID/trajectories/$TRAJ_ID" "$ID/run"
printf 'name=testid\ncreated=test\nroot_trajectory=%s\n' "$TRAJ_ID" > "$ID/info.txt"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"
: > "$TRAJ"
printf 'test-token\n' > "$ID/run/dispatcher.token"   # arm_wake requires it

# --- stubs -------------------------------------------------------------------
mkdir -p "$WORK/stub"
# shellm: record the LLM_MAX_TIME the step invoked us with; append nothing.
cat > "$WORK/stub/shellm" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${LLM_MAX_TIME-UNSET}" >> "$STUB_MAXTIME"
printf '%s\n' "${SHELLM_WAKE:-}" >> "$STUB_WAKES"
exit 0
STUB
# chat: `pending --json` prints an empty list; anything else is a no-op.
cat > "$WORK/stub/chat" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "pending" ]]; then
    printf '[]'
fi
exit 0
STUB
chmod +x "$WORK/stub/shellm" "$WORK/stub/chat"

export STUB_MAXTIME="$WORK/maxtime"
export STUB_WAKES="$WORK/wakes"

run_step() {  # $1 = trigger json; extra env as VAR=VAL args after it
    printf '%s' "$1" | env \
        PATH="$WORK/stub:$REPO/bin:$PATH" \
        IDENTITY_DIR="$ID" IDENTITY_NAME=testid MEM_DIR="$ID/memories" \
        TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID" HOME="$WORK/home" \
        MONOLITH_TIERED_MEMORY=0 MONOLITH_SHARE_HINT_EVERY=0 \
        "${@:2}" "$STEP" >> "$WORK/step.log" 2>&1
}
WAKE='{"type":"monolith-wake","content":"wake","source":"monolith-timer"}'

seen() { tail -n 1 "$STUB_MAXTIME" 2>/dev/null; }
reset_state() {
    rm -f "$ID/run/monolith_backoff_state.json" "$ID/run/monolith.wake_at" \
          "$STUB_MAXTIME" "$STUB_WAKES"
    : > "$TRAJ"; : > "$WORK/step.log"
}
check_arm() {  # $1 = label, $2 = expected, rest = extra env for run_step
    local label="$1" want="$2"
    reset_state
    run_step "$WAKE" "${@:3}"
    local got; got="$(seen)"
    if [[ "$got" == "$want" ]]; then
        ok "$label"
    else
        bad "$label" "step invoked shellm with LLM_MAX_TIME='$got', want '$want'"
    fi
}

# --- 1. no ceiling in the environment: the step raises the default ------------
check_arm "unset LLM_MAX_TIME: wake run gets 1800s, not bin/llm's 600s default" 1800

# --- 2. a pre-set ceiling wins: the step must not clobber it ------------------
check_arm "pre-set LLM_MAX_TIME=900 wins over the 1800s raise" 900 LLM_MAX_TIME=900

# --- 3. an explicit 0 (ceiling disabled) is a choice the step preserves -------
check_arm "explicit LLM_MAX_TIME=0 (no ceiling) is preserved" 0 LLM_MAX_TIME=0

# --- 4. an empty value is treated as unset ------------------------------------
check_arm "empty LLM_MAX_TIME reads as unset and gets the 1800s raise" 1800 LLM_MAX_TIME=

# --- 5. the wake really ran (the stub saw a wake reason) ---------------------
reset_state
run_step "$WAKE"
if [[ -s "$STUB_MAXTIME" ]]; then
    ok "the step invoked shellm once per wake (stub recorded an invocation)"
else
    bad "the step never invoked shellm" "no invocation recorded"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
