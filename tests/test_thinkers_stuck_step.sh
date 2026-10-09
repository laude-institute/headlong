#!/usr/bin/env bash
# test_thinkers_stuck_step.sh — dispatcher stuck-step guard (THINKERS_STEP_GRACE)
#
# Usage: tests/test_thinkers_stuck_step.sh
#
# A step whose shellm run has written its final step should exit within
# seconds. One that is still alive THINKERS_STEP_GRACE seconds later is
# wedged (2026-09-14: leftover processes held its output pipe open for six
# hours; the EXIT trap that arms the next wake never ran). The dispatcher
# attributes the final to the step through the run's launched_by, sends
# TERM after the grace, KILL 15s later, and appends one error step. A step
# with no final, or a final from a run it did not launch, is left alone.
#
# The quiet-step guard (THINKERS_STEP_QUIET) is the backstop: a step that
# puts nothing on the trajectory for that long is ended the same way, final
# or not (2026-10-07: shellm echoed a dead command's output for 26 hours).
# Every step of the run it launched restarts the clock.
# Fake thinker, no LLM, no docker. Runtime ~75s.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
PATH="$REPO/bin:$PATH"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

TMP=$(mktemp -d)
TRAJ_ID="cafe0000-0000-0000-0000-000000000007"
TRAJ="$TMP/id/trajectories/$TRAJ_ID/trajectory.jsonl"
RUN="$TMP/id/run"

env_run() {
    IDENTITY_DIR="$TMP/id" IDENTITY_NAME=testid \
    TRAJ_DIR="$TMP/id/trajectories" TRAJ_ID="$TRAJ_ID" \
    THINKERS_DIR="$TMP/id/thinkers" MEM_DIR="$TMP/id/memories" \
    THINKERS_STEP_GRACE="${GRACE:-3}" THINKERS_STEP_QUIET="${QUIET:-0}" \
    "$@"
}
cleanup() { env_run thinkers stop >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

# Fake thinker "runner": on each trigger it writes what a shellm run would —
# a shellm-run step carrying launched_by, then (per $IDENTITY_DIR/mode) a
# final for that run, a final for some OTHER run, or no final — and then
# sleeps as a wedged step would. It records every trigger it receives.
setup_identity() {
    env_run thinkers stop >/dev/null 2>&1 || true
    rm -rf "$TMP/id"
    mkdir -p "$TMP/id/thinkers/runner" "$TMP/id/trajectories/$TRAJ_ID" "$TMP/id/memories"
    printf 'name=testid\ncreated=test\nroot_trajectory=%s\n' "$TRAJ_ID" > "$TMP/id/info.txt"
    : > "$TRAJ"
    cat > "$TMP/id/thinkers/runner/step" <<'EOS'
#!/usr/bin/env bash
json=$(cat)
printf '%s\n' "$json" >> "$IDENTITY_DIR/record"
trap 'echo "exit-trap-ran" >> "$IDENTITY_DIR/record"' EXIT
mode=$(cat "$IDENTITY_DIR/mode" 2>/dev/null || echo final)
traj="$TRAJ_DIR/$TRAJ_ID/trajectory.jsonl"
rid="run-$$"
printf '{"type":"shellm-run","step_id":"%s","launched_by":"runner","command":"x","ts":"%s"}\n' "$rid" "$(date -u +%FT%T.000Z)" >> "$traj"
sleep 1
case "$mode" in
    final)  printf '{"type":"final","step_id":"f-%s","run_id":"%s","content":"done","ts":"%s"}\n' "$$" "$rid" "$(date -u +%FT%T.000Z)" >> "$traj" ;;
    other)  printf '{"type":"final","step_id":"f-%s","run_id":"someone-elses-run","content":"done","ts":"%s"}\n' "$$" "$(date -u +%FT%T.000Z)" >> "$traj" ;;
    none)   : ;;
    steps)  for _ in 1 2 3 4 5; do
                printf '{"type":"reasoning","step_id":"r-%s-%s","run_id":"%s","thought":"x","ts":"%s"}\n' "$$" "$_" "$rid" "$(date -u +%FT%T.000Z)" >> "$traj"
                sleep 2
            done ;;
esac
sleep 120
exit 0
EOS
    chmod +x "$TMP/id/thinkers/runner/step"
    printf '{"types":["action"],"trigger_self":false}\n' > "$TMP/id/thinkers/runner/subscriptions.jsonl"
}

append_step() { printf '%s\n' "$1" >> "$TRAJ"; }
start_thinkers() { env_run thinkers start >/dev/null 2>&1; sleep 2; }
stop_thinkers()  { env_run thinkers stop >/dev/null 2>&1; }
step_pid() { awk '$2=="runner"{print $1}' "$RUN/step_pids" 2>/dev/null | head -n 1; }
wait_for() {  # <seconds> <cmd...>
    local i=0 t="$1"; shift
    while ! "$@" && (( i < t )); do sleep 1; i=$((i+1)); done
    "$@"
}
error_steps() { local n; n=$(grep -c "\"reason\":\"${1:-step-stuck}\"" "$TRAJ" 2>/dev/null) || n=0; printf '%s\n' "${n:-0}"; }
pid_gone() { local p; p=$(step_pid); [[ -z "$p" ]] || ! kill -0 "$p" 2>/dev/null; }

# Test 1: a step that outlives its run's final is ended after the grace
test_stuck_step_is_ended() {
    setup_identity
    echo final > "$TMP/id/mode"
    start_thinkers
    append_step '{"type":"action","content":"go","source":"test","ts":"'"$(date -u +%FT%T.000Z)"'"}'
    wait_for 8 test -s "$TMP/id/record"
    p=$(step_pid)
    if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then ok "step is running after its final"; else bad "step is running after its final"; fi
    # grace 3s after the final (+1s ticks): gone well within 15s
    if wait_for 15 pid_gone; then ok "step ended after the grace"; else bad "step ended after the grace" "pid $p still alive"; fi
    if grep -q 'STUCK: runner step' "$RUN/logs/dispatcher.log"; then ok "dispatcher log names the stuck step"
    else bad "dispatcher log names the stuck step" "$(tail -n 4 "$RUN/logs/dispatcher.log" | tr '\n' ' ')"; fi
    if wait_for 5 test "$(error_steps)" -eq 1; then ok "one step-stuck error step appended"
    else bad "one step-stuck error step appended" "count=$(error_steps)"; fi
    if grep -q 'exit-trap-ran' "$TMP/id/record"; then ok "TERM let the step's EXIT trap run"
    else bad "TERM let the step's EXIT trap run" "record: $(tr '\n' '|' < "$TMP/id/record" | cut -c1-200); log: $(grep -c STUCK "$RUN/logs/dispatcher.log") STUCK lines"; fi
    stop_thinkers
}

# Test 2: a step whose run has not finished is left alone past the grace
test_running_step_untouched() {
    setup_identity
    echo none > "$TMP/id/mode"
    start_thinkers
    append_step '{"type":"action","content":"go","source":"test","ts":"'"$(date -u +%FT%T.000Z)"'"}'
    wait_for 8 test -s "$TMP/id/record"
    sleep 8
    p=$(step_pid)
    if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then ok "step with no final still running after the grace"
    else bad "step with no final still running after the grace"; fi
    if [[ "$(error_steps)" -eq 0 ]]; then ok "no error step without a final"; else bad "no error step without a final"; fi
    stop_thinkers
}

# Test 3: a final from a run this step did not launch does not count
test_foreign_final_ignored() {
    setup_identity
    echo other > "$TMP/id/mode"
    start_thinkers
    append_step '{"type":"action","content":"go","source":"test","ts":"'"$(date -u +%FT%T.000Z)"'"}'
    wait_for 8 test -s "$TMP/id/record"
    sleep 8
    p=$(step_pid)
    if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then ok "foreign final leaves the step running"
    else bad "foreign final leaves the step running"; fi
    stop_thinkers
}

# Test 4: THINKERS_STEP_GRACE=0 disables the guard
test_guard_disabled() {
    setup_identity
    echo final > "$TMP/id/mode"
    GRACE=0 start_thinkers
    append_step '{"type":"action","content":"go","source":"test","ts":"'"$(date -u +%FT%T.000Z)"'"}'
    wait_for 8 test -s "$TMP/id/record"
    sleep 8
    p=$(step_pid)
    if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then ok "grace 0 leaves a stuck step alone"
    else bad "grace 0 leaves a stuck step alone"; fi
    GRACE=0 stop_thinkers
}

# Test 5: a step that writes nothing is ended at the quiet limit, final or not
test_quiet_step_is_ended() {
    setup_identity
    echo none > "$TMP/id/mode"
    QUIET=4 start_thinkers
    append_step '{"type":"action","content":"go","source":"test","ts":"'"$(date -u +%FT%T.000Z)"'"}'
    wait_for 8 test -s "$TMP/id/record"
    p=$(step_pid)
    if wait_for 15 pid_gone; then ok "quiet step ended at the quiet limit"; else bad "quiet step ended at the quiet limit" "pid $p still alive"; fi
    if grep -q 'STUCK: runner step .* has put nothing on the trajectory' "$RUN/logs/dispatcher.log"; then ok "dispatcher log names the quiet step"
    else bad "dispatcher log names the quiet step" "$(tail -n 4 "$RUN/logs/dispatcher.log" | tr '\n' ' ')"; fi
    if wait_for 5 test "$(error_steps step-quiet)" -eq 1; then ok "one step-quiet error step appended"
    else bad "one step-quiet error step appended" "count=$(error_steps step-quiet)"; fi
    if grep -q 'exit-trap-ran' "$TMP/id/record"; then ok "TERM let the quiet step's EXIT trap run"
    else bad "TERM let the quiet step's EXIT trap run"; fi
    QUIET=4 stop_thinkers
}

# Test 6: steps of the run restart the quiet clock; it fires once they stop
test_progress_restarts_quiet_clock() {
    setup_identity
    echo steps > "$TMP/id/mode"
    QUIET=4 start_thinkers
    append_step '{"type":"action","content":"go","source":"test","ts":"'"$(date -u +%FT%T.000Z)"'"}'
    wait_for 8 test -s "$TMP/id/record"
    sleep 8   # twice the limit, with a step every 2s
    p=$(step_pid)
    if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && [[ "$(error_steps step-quiet)" -eq 0 ]]; then
        ok "step that keeps writing steps outlives the quiet limit"
    else bad "step that keeps writing steps outlives the quiet limit"; fi
    if wait_for 20 pid_gone; then ok "step ended once its run went quiet"; else bad "step ended once its run went quiet" "pid $p still alive"; fi
    QUIET=4 stop_thinkers
}

test_stuck_step_is_ended
test_running_step_untouched
test_foreign_final_ignored
test_guard_disabled
test_quiet_step_is_ended
test_progress_restarts_quiet_clock

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
