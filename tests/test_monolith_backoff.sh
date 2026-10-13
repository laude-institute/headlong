#!/usr/bin/env bash
# test_monolith_backoff.sh — monolith backoff: visible work vs thought-only,
# the thought cap, idle ownership, the error descent, and the share nudge.
#
# Usage: tests/test_monolith_backoff.sh
#
# Drives thinkers/monolith/step directly against a throwaway identity with a
# stubbed `shellm` on PATH. STUB_MODE_FILE selects observations, thoughts,
# self-idles, foreign idles, machinery, empty runs, or failures with and without
# an idle or diagnostic. The stub records run IDs and captures --prompt-file
# contents so the share nudge can be asserted. No LLM calls, docker or dispatcher.
# The step's state file (monolith_backoff_state.json) and wake_at file are the
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
# Appends a step per STUB_MODE_FILE and captures the prompt.
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
run_id="stub-run-$$"
printf '%s' "$run_id" > "$SHELLM_RUN_ID_OUT"
printf '%s' "$run_id" > "$STUB_LAST_RUN_ID"
case "$mode" in
    obs)     printf '{"type":"observation","step_id":"o-%s","content":"did a thing","source":"monolith"}\n' "$n" >> "$STUB_TRAJ" ;;
    thought) printf '{"type":"thought","step_id":"t-%s","content":"nothing changed","source":"monolith"}\n' "$n" >> "$STUB_TRAJ" ;;
    idle|idle-fail|idle-foreign-last)
             printf '{"type":"idle","step_id":"i-%s","run_id":"%s","content":"idle","source":"monolith"}\n' "$n" "$run_id" >> "$STUB_TRAJ"
             [[ "$mode" == idle-fail ]] && exit 3
             if [[ "$mode" == idle-foreign-last ]]; then
                 printf '{"type":"idle","step_id":"foreign","run_id":"other-run","source":"monolith"}\n' >> "$STUB_TRAJ"
             fi ;;
    foreign) printf '{"type":"idle","step_id":"foreign","run_id":"other-run","source":"monolith"}\n' >> "$STUB_TRAJ" ;;
    machinery) printf '{"type":"shell-output","step_id":"s-%s","run_id":"%s","exit":0}\n' "$n" "$run_id" >> "$STUB_TRAJ" ;;
    no-run-id) : > "$SHELLM_RUN_ID_OUT"
               printf '{"type":"idle","step_id":"unowned","run_id":"","source":"monolith"}\n' >> "$STUB_TRAJ" ;;
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
# Avoid a missing identity command adding a prompt-error row before the work
# probe. The tail-window regression needs its seeded idle at the exact edge.
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/stub/identity"
chmod +x "$WORK/stub/identity"

export STUB_MODE_FILE="$WORK/mode"
export STUB_TRAJ="$TRAJ"
export STUB_CAPTURE="$WORK/prompt-captured"
export STUB_LAST_RUN_ID="$WORK/last-run-id"
export SHELLM_MODEL="test-model"

STATE="$ID/run/monolith_backoff_state.json"
WAKE_AT="$ID/run/monolith.wake_at"

run_step() {  # $1 = trigger json
    printf '%s' "$1" | env \
        PATH="$WORK/stub:$REPO/bin:$PATH" \
        IDENTITY_DIR="$ID" IDENTITY_NAME=testid MEM_DIR="$ID/memories" \
        TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID" HOME="$WORK/home" \
        MONOLITH_TIERED_MEMORY=0 SHELLM_RAW_TAIL_LINES=5000 \
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
idle_count() { jq -s '[.[] | select(.type == "idle")] | length' "$TRAJ"; }
run_idle_count() {
    jq -s --arg rid "$(cat "$STUB_LAST_RUN_ID")" \
        '[.[] | select(.type == "idle" and .run_id == $rid)] | length' "$TRAJ"
}

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
if [[ "$(lvl)" = 2 && "$(idle_count)" = 2 && "$(run_idle_count)" = 1 ]] && near "$d" 10; then
    ok "empty wake: idle appended, full ladder (no thought cap)"
else
    bad "empty wake: idle appended, full ladder (no thought cap)" "level=$(lvl) delay=$d"
fi

# --- 5b. run idled on its own: fallback marker suppressed (no double idle) ----
reset_state
echo idle > "$STUB_MODE_FILE"
run_step "$WAKE"
n_idle=$(grep -c '"type":"idle"' "$TRAJ")
if [[ "$n_idle" = 1 && "$(run_idle_count)" = 1 ]] && near "$(delay)" 5; then
    ok "self-idle: exactly one idle row, fallback suppressed, ladder advances"
else
    bad "self-idle: exactly one idle row, fallback suppressed, ladder advances" "idle_rows=$n_idle delay=$(delay) level=$(lvl)"
fi

# --- 5c. successive self-idles each keep one marker and advance backoff ------
run_step "$WAKE"
if [[ "$(idle_count)" = 2 && "$(run_idle_count)" = 1 && "$(lvl)" = 2 ]] && near "$(delay)" 10; then
    ok "successive self-idles: one marker per run, full backoff ladder"
else
    bad "successive self-idles: one marker per run, full backoff ladder"
fi

# --- 5d. a previous fallback does not duplicate the next run's own idle ------
reset_state
echo none > "$STUB_MODE_FILE"
run_step "$WAKE"
echo idle > "$STUB_MODE_FILE"
run_step "$WAKE"
if [[ "$(idle_count)" = 2 && "$(run_idle_count)" = 1 ]] && near "$(delay)" 10; then
    ok "self-idle after a fallback: exactly one new idle"
else
    bad "self-idle after a fallback: exactly one new idle"
fi

# --- 5e. an old idle leaving the bounded probe is not a new self-idle --------
reset_state
printf '{"type":"idle","step_id":"old-idle","run_id":"old-run"}\n' >> "$TRAJ"
awk 'BEGIN { for (i=1; i<5000; i++) print "{\"type\":\"shell-output\"}" }' >> "$TRAJ"
echo machinery > "$STUB_MODE_FILE"
run_step "$WAKE"
if [[ "$(idle_count)" = 2 && "$(run_idle_count)" = 1 ]] && near "$(delay)" 5; then
    ok "historical idle leaves probe: current run still gets its fallback"
else
    bad "historical idle leaves probe: current run still gets its fallback"
fi

# --- 5f. another run's idle cannot suppress this run's fallback --------------
reset_state
echo foreign > "$STUB_MODE_FILE"
run_step "$WAKE"
if [[ "$(idle_count)" = 2 && "$(run_idle_count)" = 1 ]] && near "$(delay)" 5; then
    ok "foreign idle: current run still gets its fallback"
else
    bad "foreign idle: current run still gets its fallback"
fi

# --- 5g. a later foreign idle does not hide the current run's own idle -------
reset_state
echo idle-foreign-last > "$STUB_MODE_FILE"
run_step "$WAKE"
if [[ "$(idle_count)" = 2 && "$(run_idle_count)" = 1 ]] && near "$(delay)" 5; then
    ok "self-idle before a foreign idle: no duplicate fallback"
else
    bad "self-idle before a foreign idle: no duplicate fallback"
fi

# --- 5h. an unavailable run ID cannot claim an unowned idle ------------------
reset_state
echo no-run-id > "$STUB_MODE_FILE"
run_step "$WAKE"
if [[ "$(idle_count)" = 2 ]] && near "$(delay)" 5; then
    ok "missing run ID: fallback retained"
else
    bad "missing run ID: fallback retained"
fi

# --- 5i. self-idle followed by failure still records the error ---------------
reset_state
echo idle-fail > "$STUB_MODE_FILE"
run_step "$WAKE"
n_error=$(jq -s --arg rid "$(cat "$STUB_LAST_RUN_ID")" \
    '[.[] | select(.type == "error" and .run_id == $rid and .rc == 3)] | length' "$TRAJ")
if [[ "$(idle_count)" = 1 && "$n_error" = 1 && "$(lvl)" = 1 ]] && near "$(delay)" 5; then
    ok "idle then failure: error recorded, no extra idle, error backoff"
else
    bad "idle then failure: error recorded, no extra idle, error backoff"
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
