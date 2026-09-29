#!/usr/bin/env bash
# test_thinkers_wake_at.sh — dispatcher-native scheduled wake (run/<name>.wake_at)
#
# Usage:
#   tests/test_thinkers_wake_at.sh
#
# A thinker asks to be woken later by writing a target epoch to
# run/<name>.wake_at; the dispatcher tick fires a monolith-wake trigger when
# it comes due and consumes the file (design/monolith_backoff.md, Alternative
# 3). No timer process is involved, so this works the same on macOS, where
# setsid does not exist. Uses a fake thinker that records its stdin; no LLM
# calls, no docker. Runtime ~30s (1s ticks plus a 4s busy window).

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
PATH="$REPO/bin:$PATH"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

TMP=$(mktemp -d)
TRAJ_ID="cafe0000-0000-0000-0000-000000000002"
RUN="$TMP/id/run"

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

# One fake thinker, "napper": records each trigger it receives, then sleeps
# for the number of seconds in $IDENTITY_DIR/nap (default 0) so a test can
# hold it busy on demand.
setup_identity() {
    env_run thinkers stop >/dev/null 2>&1 || true
    rm -rf "$TMP/id"
    mkdir -p "$TMP/id/thinkers/napper" "$TMP/id/trajectories/$TRAJ_ID" "$TMP/id/memories"
    printf 'name=testid\ncreated=test\nroot_trajectory=%s\n' "$TRAJ_ID" > "$TMP/id/info.txt"
    : > "$TMP/id/trajectories/$TRAJ_ID/trajectory.jsonl"

    cat > "$TMP/id/thinkers/napper/step" <<'EOF'
#!/usr/bin/env bash
json=$(cat)
printf '%s\n' "$json" >> "$IDENTITY_DIR/record"
nap=$(cat "$IDENTITY_DIR/nap" 2>/dev/null || echo 0)
[[ "$nap" -gt 0 ]] && sleep "$nap"
exit 0
EOF
    chmod +x "$TMP/id/thinkers/napper/step"
    printf '{"types":["action","monolith-wake"],"trigger_self":false}\n' > "$TMP/id/thinkers/napper/subscriptions.jsonl"
}

append_step() {
    printf '%s\n' "$1" >> "$TMP/id/trajectories/$TRAJ_ID/trajectory.jsonl"
}

start_thinkers() { env_run thinkers start >/dev/null 2>&1; sleep 2; }
stop_thinkers()  { env_run thinkers stop >/dev/null 2>&1; }

record_count() {
    if [[ -f "$TMP/id/record" ]]; then wc -l < "$TMP/id/record" | tr -d ' '; else echo 0; fi
}

wait_for_record() {
    local want="$1" timeout="${2:-10}" i=0
    while [[ "$(record_count)" -lt "$want" && "$i" -lt "$timeout" ]]; do
        sleep 1; i=$((i+1))
    done
}

wait_for_file_gone() {
    local f="$1" timeout="${2:-10}" i=0
    while [[ -f "$f" && "$i" -lt $((timeout * 10)) ]]; do
        sleep 0.1; i=$((i+1))
    done
}

now() { date +%s; }

# ---------------------------------------------------------------------------
# Test 1: a due wake_at fires exactly one monolith-wake trigger, on stdin,
# and the file is consumed. Nothing lands in the trajectory.
# ---------------------------------------------------------------------------
test_due_wake_fires_once() {
    setup_identity
    start_thinkers

    printf '%s' "$(( $(now) - 1 ))" > "$RUN/napper.wake_at"
    wait_for_record 1
    if [[ "$(record_count)" -eq 1 ]] && grep -q '"type":"monolith-wake"' "$TMP/id/record" 2>/dev/null; then
        ok "due wake_at fires a monolith-wake trigger"
    else
        bad "due wake_at fires a monolith-wake trigger" "record: $(cat "$TMP/id/record" 2>/dev/null | tr '\n' ' ')"
    fi

    wait_for_file_gone "$RUN/napper.wake_at" 3
    if [[ ! -f "$RUN/napper.wake_at" ]]; then
        ok "wake_at consumed after firing"
    else
        bad "wake_at consumed after firing"
    fi

    sleep 3
    if [[ "$(record_count)" -eq 1 ]]; then
        ok "fires exactly once"
    else
        bad "fires exactly once" "record count: $(record_count)"
    fi

    if ! grep -q 'monolith-wake' "$TMP/id/trajectories/$TRAJ_ID/trajectory.jsonl"; then
        ok "no machinery step appended to the trajectory"
    else
        bad "no machinery step appended to the trajectory"
    fi

    if grep -q 'scheduled wake -> napper' "$RUN/logs/dispatcher.log" 2>/dev/null; then
        ok "scheduled wake logged by dispatcher"
    else
        bad "scheduled wake logged by dispatcher"
    fi

    stop_thinkers
}

# ---------------------------------------------------------------------------
# Test 2: a wake_at in the future waits, then fires when its time comes
# (no early firing).
# ---------------------------------------------------------------------------
test_future_wake_waits() {
    setup_identity
    start_thinkers

    printf '%s' "$(( $(now) + 4 ))" > "$RUN/napper.wake_at"
    sleep 2
    if [[ "$(record_count)" -eq 0 && -f "$RUN/napper.wake_at" ]]; then
        ok "future wake_at not fired early"
    else
        bad "future wake_at not fired early" "record count: $(record_count)"
    fi

    wait_for_record 1 8
    if [[ "$(record_count)" -eq 1 ]]; then
        ok "future wake_at fires when due"
    else
        bad "future wake_at fires when due"
    fi

    stop_thinkers
}

# ---------------------------------------------------------------------------
# Test 3: a due wake is deferred (file kept) while the thinker is busy, and
# fires after it frees up. The step run keeps the wake, it does not drop it.
# ---------------------------------------------------------------------------
test_busy_defers() {
    setup_identity
    start_thinkers

    printf '4' > "$TMP/id/nap"
    append_step '{"type":"action","content":"A","source":"test"}'
    wait_for_record 1                      # napper is now busy for ~4s
    printf '%s' "$(( $(now) - 1 ))" > "$RUN/napper.wake_at"
    sleep 2
    if [[ -f "$RUN/napper.wake_at" && "$(record_count)" -eq 1 ]]; then
        ok "due wake_at held while thinker busy"
    else
        bad "due wake_at held while thinker busy" "file present: $([[ -f "$RUN/napper.wake_at" ]] && echo yes || echo no), record count: $(record_count)"
    fi

    printf '0' > "$TMP/id/nap"
    wait_for_record 2 10
    if [[ "$(record_count)" -eq 2 ]] && tail -1 "$TMP/id/record" | grep -q '"monolith-wake"'; then
        ok "deferred wake fires after thinker frees up"
    else
        bad "deferred wake fires after thinker frees up" "record: $(cat "$TMP/id/record" 2>/dev/null | tr '\n' ' ')"
    fi

    stop_thinkers
}

# ---------------------------------------------------------------------------
# Test 4: a completed asynchronous step is pruned from the ledger. The stall
# this pins: pruning used to run inside command substitution, so the pruned
# ledger was discarded with the subshell — _step_entries grew one dead PID
# per dispatched step, and a kernel-recycled stale PID then passed `kill -0`
# and left its thinker busy forever. The on-disk prune below is the
# observable half of the in-shell prune.
# ---------------------------------------------------------------------------
test_finished_step_reaped() {
    local old_pid
    setup_identity
    start_thinkers

    # A nonzero nap keeps the step alive past wait_for_record, so step_pids
    # still holds its entry when read (with 0 it can already be pruned,
    # leaving old_pid empty and the assertion below vacuous).
    printf '2' > "$TMP/id/nap"
    append_step '{"type":"action","content":"A","source":"test"}'
    wait_for_record 1
    old_pid=$(awk 'NR == 1 {print $1}' "$RUN/step_pids")
    if [[ -z "$old_pid" ]]; then
        bad "captured prior step pid" "step_pids: $(cat "$RUN/step_pids" 2>/dev/null | tr '\n' ' ')"
    fi

    printf '%s' "$(( $(now) - 1 ))" > "$RUN/napper.wake_at"
    wait_for_record 2 8
    if [[ "$(record_count)" -eq 2 ]] && tail -1 "$TMP/id/record" | grep -q '"monolith-wake"'; then
        ok "scheduled wake fires after prior child exits"
    else
        bad "scheduled wake fires after prior child exits" "record: $(cat "$TMP/id/record" 2>/dev/null | tr '\n' ' ')"
    fi
    if ! grep -q "^$old_pid " "$RUN/step_pids" 2>/dev/null; then
        ok "completed thinker step removed from process list"
    else
        bad "completed thinker step removed from process list" "step_pids: $(cat "$RUN/step_pids" 2>/dev/null | tr '\n' ' ')"
    fi

    stop_thinkers
}

# ---------------------------------------------------------------------------
# Test 5: garbage content and wake_at for a thinker that is not active are
# dropped without firing.
# ---------------------------------------------------------------------------
test_bad_files_dropped() {
    setup_identity
    start_thinkers

    printf 'soon' > "$RUN/napper.wake_at"
    printf '%s' "$(( $(now) - 1 ))" > "$RUN/nobody.wake_at"
    wait_for_file_gone "$RUN/napper.wake_at" 5
    wait_for_file_gone "$RUN/nobody.wake_at" 5
    if [[ ! -f "$RUN/napper.wake_at" && ! -f "$RUN/nobody.wake_at" ]]; then
        ok "garbage and unknown-thinker wake_at files removed"
    else
        bad "garbage and unknown-thinker wake_at files removed"
    fi
    sleep 1
    if [[ "$(record_count)" -eq 0 ]]; then
        ok "nothing fired for bad wake_at files"
    else
        bad "nothing fired for bad wake_at files"
    fi

    stop_thinkers
}

# ---------------------------------------------------------------------------
# Test 6: `thinkers stop` drops a pending wake_at so it cannot fire a thinker
# the operator just stopped.
# ---------------------------------------------------------------------------
test_stop_clears_wake_at() {
    setup_identity
    start_thinkers

    printf '%s' "$(( $(now) + 600 ))" > "$RUN/napper.wake_at"
    stop_thinkers
    if [[ ! -f "$RUN/napper.wake_at" ]]; then
        ok "stop removes pending wake_at"
    else
        bad "stop removes pending wake_at"
    fi
}

# ---------------------------------------------------------------------------

printf 'test_thinkers_wake_at: using tmp dir %s\n' "$TMP"
# ---------------------------------------------------------------------------
# Test 7: a stale claim that collides with an existing wake_at for the same
# name is dropped and the scheduled wake_at keeps its own due time. The claim
# due time is always in the past, so re-arming it over a future wake_at fires
# the name early.
# ---------------------------------------------------------------------------
test_stale_claim_keeps_scheduled_wake_at() {
    setup_identity
    start_thinkers
    local due later got
    due=$(( $(now) - 3600 ))
    later=$(( $(now) + 600 ))
    mkdir -p "$RUN/claimed"
    printf '%s' "$due" > "$RUN/claimed/napper"
    touch -t 202001010000 "$RUN/claimed/napper" 2>/dev/null
    printf '%s' "$later" > "$RUN/napper.wake_at"
    wait_for_file_gone "$RUN/claimed/napper" 5
    sleep 2
    if [[ ! -f "$RUN/claimed/napper" ]]; then
        ok "stale claim dropped when a wake_at already holds the name"
    else
        bad "stale claim dropped when a wake_at already holds the name"
    fi
    got=$(cat "$RUN/napper.wake_at" 2>/dev/null)
    if [[ "$got" == "$later" ]]; then
        ok "scheduled wake_at kept its own due time"
    else
        bad "scheduled wake_at kept its own due time" "want $later, got '$got'"
    fi
    if [[ "$(record_count)" == "0" ]]; then
        ok "no wake fired early from the collision"
    else
        bad "no wake fired early from the collision" "$(record_count) triggers recorded"
    fi
    stop_thinkers
}

# ---------------------------------------------------------------------------
# Test 8: a stale claim with no wake_at to defer to is still re-armed from its
# own due time and fires exactly one wake.
# ---------------------------------------------------------------------------
test_stale_claim_rearm_fires_once() {
    setup_identity
    start_thinkers
    mkdir -p "$RUN/claimed"
    printf '%s' "$(( $(now) - 5 ))" > "$RUN/claimed/napper"
    touch -t 202001010000 "$RUN/claimed/napper" 2>/dev/null
    wait_for_record 1 10
    sleep 2
    if [[ "$(record_count)" == "1" ]]; then
        ok "stale claim alone re-arms and fires exactly one wake"
    else
        bad "stale claim alone re-arms and fires exactly one wake" "$(record_count) triggers recorded"
    fi
    if [[ ! -f "$RUN/napper.wake_at" && ! -f "$RUN/claimed/napper" ]]; then
        ok "the re-armed wake consumed both the claim and the wake file"
    else
        bad "the re-armed wake consumed both the claim and the wake file"
    fi
    stop_thinkers
}

test_due_wake_fires_once
test_future_wake_waits
test_busy_defers
test_finished_step_reaped
test_bad_files_dropped
test_stop_clears_wake_at
test_stale_claim_keeps_scheduled_wake_at
test_stale_claim_rearm_fires_once

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
