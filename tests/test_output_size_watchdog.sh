#!/usr/bin/env bash
# test_output_size_watchdog.sh — the output-size guard in bin/shellm's watchdog
#
# Usage: tests/test_output_size_watchdog.sh
#
# `llm` is stubbed (a mode file drives what each call returns), so this
# exercises the real run loop. A command that produces output continuously —
# resetting the inactivity/silence counters every check — used to run forever
# (issue #116: a runaway loop grew its output to 4.69 GB over ~6 days). The
# watchdog now caps total output at SHELLM_MAX_OUTPUT_SIZE and kills the block.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK="${SHELLM_TEST_WORK:-}"
if [[ -z "$WORK" ]]; then
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
else
    rm -rf "$WORK"; mkdir -p "$WORK"
fi

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

# --- llm stub (same shape as test_inactivity_beacon.sh) ----------------------
mkdir -p "$WORK/script" "$WORK/home"
cp -R "$REPO/bin" "$WORK/toolbin"
cat > "$WORK/toolbin/llm" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == "--thinking" ]] && main_loop=1; done
if [[ "${main_loop:-0}" -ne 1 ]]; then printf '{}\n'; exit 0; fi
n=$(( $(cat "$LLM_COUNT" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" > "$LLM_COUNT"
if [[ -f "$LLM_SCRIPT/$n" ]]; then cat "$LLM_SCRIPT/$n"; else cat "$LLM_SCRIPT/last"; fi
EOF
chmod +x "$WORK/toolbin/llm"

export PATH="$WORK/toolbin:$PATH"
export LLM_COUNT="$WORK/count"
export LLM_SCRIPT="$WORK/script"
export HOME="$WORK/home"
export HEADLONG_HOME="$WORK/home/.headlong"
export ANTHROPIC_API_KEY="test-key"
export SHELLM_MODEL="test-model"
export SHELLM_ENV=local

TIMEOUT=""
for _t in timeout gtimeout; do
    if command -v "$_t" >/dev/null 2>&1; then TIMEOUT="$_t 120"; break; fi
done

run_shellm() {
    : > "$LLM_COUNT"
    rm -rf "$WORK/wd"; mkdir -p "$WORK/wd"
    ( cd "$WORK/wd" && $TIMEOUT "$WORK/toolbin/shellm" --workdir "$WORK/wd" \
        --max-iterations 2 "$@" ) > "$WORK/out" 2> "$WORK/err" < /dev/null
}

fence() { printf '```bash\n%s\n```\n' "$1"; }

# --- runaway output is killed at SHELLM_MAX_OUTPUT_SIZE ----------------------
# The finite deadline also bounds a broken implementation. Check a side effect
# after shellm returns: killing just the execution wrapper used to report a
# successful kill while this producer kept running through its open output fd.
fence 'echo $$ > producer.pid; end=$((SECONDS+10)); while [ $SECONDS -lt $end ]; do printf "x%.0s" {1..1000}; echo; echo tick >> heartbeat; sleep 0.05; done; echo completed > completed' > "$WORK/script/1"
fence 'FINAL=done' > "$WORK/script/last"
SHELLM_MAX_OUTPUT_SIZE=50000 SHELLM_INACTIVITY_TIMEOUT=600 SHELLM_INACTIVITY_MAX=600 \
    run_shellm "runaway case"

if grep -q 'shellm-watchdog\] output timeout' "$WORK/err"; then
    ok "runaway output is killed at SHELLM_MAX_OUTPUT_SIZE"
else
    bad "runaway output is killed at SHELLM_MAX_OUTPUT_SIZE" "$(tail -3 "$WORK/err")"
fi

# The feedback the model sees names the real cause (output size), not an
# interactive prompt or a dead sub-run.
runaway_traj=("$HEADLONG_HOME/trajectories"/*runaway-case/trajectory.jsonl)
if grep -q 'output grew past' "${runaway_traj[@]}" 2>/dev/null; then
    ok "kill feedback names the output-size cause"
else
    bad "kill feedback names the output-size cause" \
        "$(grep -o '"type":"feedback"[^}]*' "${runaway_traj[@]}" 2>/dev/null | head -c 200)"
fi

producer=$(cat "$WORK/wd/producer.pid" 2>/dev/null || echo 0)
before=$(wc -l < "$WORK/wd/heartbeat")
sleep 0.3
after=$(wc -l < "$WORK/wd/heartbeat")
if [[ "$producer" -gt 1 ]] && ! kill -0 "$producer" 2>/dev/null \
    && [[ "$before" -eq "$after" && ! -f "$WORK/wd/completed" ]] \
    && grep -qx 'done' "$WORK/out"; then
    ok "producer exits and stops writing before shellm returns its final answer"
else
    bad "producer exits and stops writing before shellm returns its final answer"
    [[ "$producer" -gt 1 ]] && kill "$producer" 2>/dev/null || true
fi

# The limit applies to one block, and zero keeps the previous unlimited policy.
fence 'end=$((SECONDS+2)); while [ $SECONDS -lt $end ]; do printf "x%.0s" {1..1000}; echo; sleep 0.05; done; echo completed > completed' > "$WORK/script/1"
for limit in 0 104857600; do
    SHELLM_MAX_OUTPUT_SIZE="$limit" run_shellm "allowed case $limit"
    if [[ -f "$WORK/wd/completed" ]] && ! grep -q 'shellm-watchdog' "$WORK/err"; then
        ok "limit $limit lets bounded output finish"
    else
        bad "limit $limit lets bounded output finish"
    fi
done

# --- a heartbeat that never ends is killed at SHELLM_MAX_EXEC_TIME -----------
# The output stays tiny and never goes quiet, so only the wall-clock guard can
# stop it (Audel 2026-09-25: a scan blocked on a fifo behind an echo loop).
fence 'echo $$ > producer.pid; while :; do echo "... waiting"; sleep 1; done' > "$WORK/script/1"
SHELLM_MAX_EXEC_TIME=3 SHELLM_INACTIVITY_TIMEOUT=600 SHELLM_INACTIVITY_MAX=600 \
    run_shellm "heartbeat case"

if grep -q 'shellm-watchdog\] wall timeout' "$WORK/err"; then
    ok "endless heartbeat is killed at SHELLM_MAX_EXEC_TIME"
else
    bad "endless heartbeat is killed at SHELLM_MAX_EXEC_TIME" "$(tail -3 "$WORK/err")"
fi
wall_traj=("$HEADLONG_HOME/trajectories"/*heartbeat-case/trajectory.jsonl)
if grep -q 'the limit for one block' "${wall_traj[@]}" 2>/dev/null; then
    ok "kill feedback names the wall-clock cause"
else
    bad "kill feedback names the wall-clock cause"
fi
producer=$(cat "$WORK/wd/producer.pid" 2>/dev/null || echo 0)
if [[ "$producer" -gt 1 ]] && ! kill -0 "$producer" 2>/dev/null && grep -qx 'done' "$WORK/out"; then
    ok "heartbeat producer is gone before shellm returns"
else
    bad "heartbeat producer is gone before shellm returns"
    [[ "$producer" -gt 1 ]] && kill "$producer" 2>/dev/null || true
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
