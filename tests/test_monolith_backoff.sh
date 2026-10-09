#!/usr/bin/env bash
# test_monolith_backoff.sh — monolith backoff: visible work vs thought-only,
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
prev=""
for a in "$@"; do
    [[ "$prev" == "--prompt-file" ]] && cp "$a" "$STUB_CAPTURE"
    prev="$a"
done
mode=$(cat "$STUB_MODE_FILE" 2>/dev/null || echo none)
n=$RANDOM$RANDOM
case "$mode" in
    obs)     printf '{"type":"observation","step_id":"o-%s","content":"did a thing","source":"monolith"}\n' "$n" >> "$STUB_TRAJ" ;;
    thought) printf '{"type":"thought","step_id":"t-%s","content":"nothing changed","source":"monolith"}\n' "$n" >> "$STUB_TRAJ" ;;
    idle)    printf '{"type":"idle","step_id":"i-%s","content":"honestly nothing to do","source":"monolith"}\n' "$n" >> "$STUB_TRAJ" ;;
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
        MONOLITH_BACKOFF_BASE=5 MONOLITH_BACKOFF_FACTOR=2 \
        MONOLITH_BACKOFF_CAP=40 MONOLITH_BACKOFF_HOLD=1 \
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

# --- 1. visible work resets to level 0 / immediate re-wake -------------------
reset_state
echo obs > "$STUB_MODE_FILE"
run_step "$WAKE"
if [[ "$(lvl)" = 0 ]] && near "$(delay)" 0; then
    ok "visible work: level 0, immediate re-wake"
else
    bad "visible work: level 0, immediate re-wake" "level=$(lvl) delay=$(delay)"
fi

# --- 2. thought-only climbs the ladder but rests at THOUGHT_CAP --------------
reset_state
echo thought > "$STUB_MODE_FILE"
run_step "$WAKE"      # HOLD=1: level 0 -> 1, delay min(5, 7) = 5
d1=$(delay); l1=$(lvl)
run_step "$WAKE"      # level 1 -> 2, delay min(10, 7) = 7 (capped)
d2=$(delay); l2=$(lvl)
run_step "$WAKE"      # level 2 -> 3, delay min(20, 7) = 7
d3=$(delay)
if [[ "$l1" = 1 && "$l2" = 2 ]] && near "$d1" 5 && near "$d2" 7 && near "$d3" 7; then
    ok "thought-only: backs off, capped at THOUGHT_CAP"
else
    bad "thought-only: backs off, capped at THOUGHT_CAP" "levels=$l1,$l2 delays=$d1,$d2,$d3"
fi
if ! grep -q '"type":"idle"' "$TRAJ"; then
    ok "thought-only: no fallback idle appended (thought is durable)"
else
    bad "thought-only: no fallback idle appended (thought is durable)"
fi

# --- 3. visible work after rumination snaps back to level 0 ------------------
echo obs > "$STUB_MODE_FILE"
run_step "$WAKE"
if [[ "$(lvl)" = 0 ]] && near "$(delay)" 0; then
    ok "visible work after thoughts: snaps back to level 0"
else
    bad "visible work after thoughts: snaps back to level 0" "level=$(lvl) delay=$(delay)"
fi

# --- 4. a reactive wake resets regardless of what the run produced -----------
echo thought > "$STUB_MODE_FILE"
run_step "$WAKE"; run_step "$WAKE"   # climb a bit first
run_step "$REACTIVE"
if [[ "$(lvl)" = 0 ]] && near "$(delay)" 0; then
    ok "reactive wake: resets to level 0"
else
    bad "reactive wake: resets to level 0" "level=$(lvl) delay=$(delay)"
fi

# --- 5. empty wake: fallback idle, full-cap ladder (no thought cap) ----------
reset_state
echo none > "$STUB_MODE_FILE"
run_step "$WAKE"      # level 0 -> 1, delay 5
run_step "$WAKE"      # level 1 -> 2, delay 10 (> THOUGHT_CAP: cap not applied)
d=$(delay)
if [[ "$(lvl)" = 2 ]] && near "$d" 10 && grep -q '"type":"idle"' "$TRAJ"; then
    ok "empty wake: idle appended, full ladder (no thought cap)"
else
    bad "empty wake: idle appended, full ladder (no thought cap)" "level=$(lvl) delay=$d"
fi

# --- 5b. run idled on its own: fallback marker suppressed (no double idle) ----
reset_state
echo idle > "$STUB_MODE_FILE"
run_step "$WAKE"
n_idle=$(grep -c '"type":"idle"' "$TRAJ")
if [[ "$n_idle" = 1 ]] && near "$(delay)" 5; then
    ok "self-idle: exactly one idle row, fallback suppressed, ladder advances"
else
    bad "self-idle: exactly one idle row, fallback suppressed, ladder advances" "idle_rows=$n_idle delay=$(delay) level=$(lvl)"
fi

# --- 6. failed run: error step + immediate descent ---------------------------
reset_state
echo fail > "$STUB_MODE_FILE"
run_step "$WAKE"
if [[ "$(lvl)" = 1 ]] && near "$(delay)" 5 && grep -q '"type":"error"' "$TRAJ"; then
    ok "failed run: error step, immediate descent"
else
    bad "failed run: error step, immediate descent" "level=$(lvl) delay=$(delay)"
fi

# --- 6b. failed run WITH a shell-output: error step carries diagnostic_step ---
reset_state
echo fail-diag > "$STUB_MODE_FILE"
run_step "$WAKE"
diag=$(jq -Rr 'fromjson? // empty | select(.type=="error") | .diagnostic_step // empty' "$TRAJ" | tail -n 1)
if [[ "$diag" == "diag-so-1" ]]; then
    ok "failed run with shell-output: error step carries diagnostic_step"
else
    bad "failed run with shell-output: error step carries diagnostic_step" "diag=$diag"
fi

# --- 6c. bare failed run (no shell-output): error step has NO diagnostic_step ---
reset_state
echo fail > "$STUB_MODE_FILE"
run_step "$WAKE"
bare=$(jq -Rr 'fromjson? // empty | select(.type=="error") | .diagnostic_step // "absent"' "$TRAJ" | tail -n 1)
if [[ "$bare" == "absent" ]]; then
    ok "bare failed run: error step has no diagnostic_step (nothing to reference)"
else
    bad "bare failed run: error step has no diagnostic_step" "got=$bare"
fi

# --- 6d. failed run whose only shell-output has no exit code: diagnostic_step
#      falls back to the last non-empty step (inference-layer death) ---
reset_state
echo fail-diag-noexit > "$STUB_MODE_FILE"
run_step "$WAKE"
fb=$(jq -Rr 'fromjson? // empty | select(.type=="error") | .diagnostic_step // empty' "$TRAJ" | tail -n 1)
if [[ "$fb" == "diag-so-3" ]]; then
    ok "failed run with no-exit shell-output: diagnostic_step falls back to last non-empty"
else
    bad "failed run with no-exit shell-output: diagnostic_step falls back to last non-empty" "fb=$fb"
fi

# --- 7. share nudge: every N spontaneous wakes, then counter resets ----------
reset_state
echo thought > "$STUB_MODE_FILE"
SHARE_EVERY=2
hint='shared anything outward'
run_step "$WAKE"
h1=$(grep -c "$hint" "$STUB_CAPTURE" 2>/dev/null || true)
run_step "$WAKE"
h2=$(grep -c "$hint" "$STUB_CAPTURE" 2>/dev/null || true)
run_step "$WAKE"
h3=$(grep -c "$hint" "$STUB_CAPTURE" 2>/dev/null || true)
run_step "$WAKE"
h4=$(grep -c "$hint" "$STUB_CAPTURE" 2>/dev/null || true)
if [[ "$h1" = 0 && "$h2" = 1 && "$h3" = 0 && "$h4" = 1 ]]; then
    ok "share nudge fires every 2nd spontaneous wake"
else
    bad "share nudge fires every 2nd spontaneous wake" "hints per wake: $h1,$h2,$h3,$h4"
fi
SHARE_EVERY=0
run_step "$WAKE"
if ! grep -q "$hint" "$STUB_CAPTURE" 2>/dev/null; then
    ok "share nudge disabled with MONOLITH_SHARE_HINT_EVERY=0"
else
    bad "share nudge disabled with MONOLITH_SHARE_HINT_EVERY=0"
fi

# --- 8. the prompt menu offers share -----------------------------------------
if grep -q '\*\*share\*\*' "$STUB_CAPTURE" 2>/dev/null; then
    ok "prompt menu includes the share function"
else
    bad "prompt menu includes the share function"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
