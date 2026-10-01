#!/usr/bin/env bash
# test_inactivity_beacon.sh — the inactivity watchdog and the nested-run beacon
#
# Usage: tests/test_inactivity_beacon.sh
#
# `llm` is stubbed (a mode file drives what each call returns), so this
# exercises the real run loop: a genuinely idle block still gets killed, a
# block holding a live nested shellm run survives past the idle timeout, and a
# block whose nested run outlives SHELLM_INACTIVITY_MAX gets killed with
# feedback that names the sub-run instead of guessing at a prompt.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

# Set SHELLM_TEST_WORK to keep the scratch dir around for debugging.
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

# --- llm stub ----------------------------------------------------------------
# shellm puts its own bin directory at the front of PATH for the code it runs,
# so a stub that only sits earlier in PATH gets shadowed inside nested runs.
# Run the whole test out of a copy of bin/ with llm replaced, which keeps the
# stub in force at every level of nesting.
mkdir -p "$WORK/script" "$WORK/home"
cp -R "$REPO/bin" "$WORK/toolbin"
cat > "$WORK/toolbin/llm" <<'EOF'
#!/usr/bin/env bash
# Every run also fires a background run-summary llm call, which would race the
# main loop for call numbers. Only the main loop passes --thinking, so serve
# the script to that caller and give the summary an empty answer.
for a in "$@"; do [[ "$a" == "--thinking" ]] && main_loop=1; done
if [[ "${main_loop:-0}" -ne 1 ]]; then printf '{}\n'; exit 0; fi
n=$(( $(cat "$LLM_COUNT" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" > "$LLM_COUNT"
printf 'call %s\n' "$n" >> "$LLM_SCRIPT/trace"
[[ -f "$LLM_SCRIPT/$n.sleep" ]] && sleep "$(cat "$LLM_SCRIPT/$n.sleep")"
if [[ -f "$LLM_SCRIPT/$n" ]]; then cat "$LLM_SCRIPT/$n"; else cat "$LLM_SCRIPT/last"; fi
EOF
chmod +x "$WORK/toolbin/llm"

export PATH="$WORK/toolbin:$PATH"
export LLM_COUNT="$WORK/count"
export LLM_SCRIPT="$WORK/script"
export HOME="$WORK/home"
# The suites assert on trajectories, so the state home must stay inside WORK:
# an inherited TRAJ_DIR or SHELLM_TRAJ_DIR would move every spawned run's log
# out of the fixture and the feedback-step assertions below would go red for
# a reason that has nothing to do with the watchdog under test.
export HEADLONG_HOME="$WORK/home/.headlong"
unset TRAJ_DIR SHELLM_TRAJ_DIR
export ANTHROPIC_API_KEY="test-key"
export SHELLM_MODEL="test-model"
export SHELLM_BEACON_INTERVAL=1
# shellm defaults to Docker mode whenever `docker info` succeeds (the host
# socket on a CI runner, say). This test is about the host-side watchdog and
# beacon, and its llm stub only exists on the host, so pin local execution.
export SHELLM_ENV=local

# timeout is GNU coreutils, so it is gtimeout on a stock Mac and absent if
# coreutils is not installed. The runs are bounded by --max-iterations anyway.
TIMEOUT=""
for _t in timeout gtimeout; do
    if command -v "$_t" >/dev/null 2>&1; then TIMEOUT="$_t 120"; break; fi
done

run_shellm() {
    # Each case starts from a clean call counter and its own workdir.
    : > "$LLM_COUNT"
    rm -rf "$WORK/wd"; mkdir -p "$WORK/wd"
    : > "$LLM_SCRIPT/trace"
    ( cd "$WORK/wd" && $TIMEOUT "$WORK/toolbin/shellm" --workdir "$WORK/wd" \
        --max-iterations 2 "$@" ) > "$WORK/out" 2> "$WORK/err" < /dev/null
}

fence() { printf '```bash\n%s\n```\n' "$1"; }

# --- case 1: a genuinely idle block is still killed ---------------------------
fence 'sleep 30' > "$WORK/script/1"
fence 'FINAL=done' > "$WORK/script/last"
SHELLM_INACTIVITY_TIMEOUT=3 SHELLM_INACTIVITY_MAX=600 run_shellm "idle case"
if grep -q 'shellm-watchdog\] idle timeout' "$WORK/err"; then
    ok "idle block is killed at SHELLM_INACTIVITY_TIMEOUT"
else
    bad "idle block is killed at SHELLM_INACTIVITY_TIMEOUT" "$(tail -3 "$WORK/err")"
fi

# --- case 2: a live nested run keeps the block alive --------------------------
# The nested run's own model call stalls for 9s, well past the 3s idle timeout.
# Before the beacon, this was the exit-143 death that killed real delegation.
fence 'shellm -q --max-iterations 1 "sub task" > sub.txt 2>&1; echo "sub done"' > "$WORK/script/1"
printf '9' > "$WORK/script/2.sleep"
fence 'FINAL=sub-answer' > "$WORK/script/2"
fence 'FINAL=done' > "$WORK/script/last"
SHELLM_INACTIVITY_TIMEOUT=3 SHELLM_INACTIVITY_MAX=600 run_shellm "nested case"
if grep -q 'shellm-watchdog' "$WORK/err"; then
    bad "nested run survives past the idle timeout" "watchdog fired: $(grep shellm-watchdog "$WORK/err" | head -1)"
elif grep -q 'sub done' "$WORK/err"; then
    ok "nested run survives past the idle timeout"
else
    bad "nested run survives past the idle timeout" "block did not finish: $(tail -3 "$WORK/err")"
fi

# --- case 3: a nested run past the ceiling dies, and says why -----------------
fence 'shellm -q --max-iterations 1 "sub task" > sub.txt 2>&1; echo "sub done"' > "$WORK/script/1"
printf '30' > "$WORK/script/2.sleep"
fence 'FINAL=sub-answer' > "$WORK/script/2"
fence 'FINAL=done' > "$WORK/script/last"
# Sample the process table while the case runs. On a failure the last samples
# show every process group and which members were stopped (STAT T) when the
# tree was killed; the macOS SIGHUP death of 2026-09-17 left no other evidence.
( while :; do
      { date -u +%T; ps -axo pid=,ppid=,pgid=,stat=,command= | grep -F "$WORK" | grep -v 'grep -F' | cut -c1-160; echo; } >> "$WORK/ps.samples"
      sleep 0.5
  done ) 2>/dev/null &
sampler=$!
SHELLM_INACTIVITY_TIMEOUT=3 SHELLM_INACTIVITY_MAX=8 run_shellm "ceiling case"
ceiling_rc=$?
kill "$sampler" 2>/dev/null; wait "$sampler" 2>/dev/null
if grep -q 'shellm-watchdog\] nested timeout' "$WORK/err"; then
    ok "nested run past SHELLM_INACTIVITY_MAX is killed"
else
    bad "nested run past SHELLM_INACTIVITY_MAX is killed" "$(tail -3 "$WORK/err")"
fi
# The feedback the model sees is a trajectory step, not terminal output.
ceiling_traj=("$HEADLONG_HOME/trajectories"/*ceiling-case/trajectory.jsonl)
if grep -q 'A nested shellm run was still alive' "${ceiling_traj[@]}" 2>/dev/null; then
    ok "kill feedback names the sub-run, not an interactive prompt"
else
    bad "kill feedback names the sub-run, not an interactive prompt" \
        "shellm rc=$ceiling_rc; $(tail -10 "$WORK/err")"
    echo "--- process samples (pid ppid pgid stat command), last 120 lines:"
    tail -120 "$WORK/ps.samples" 2>/dev/null || true
    jq -c 'select(.type == "shell-output" or .type == "feedback") | {type,exit,timed_out,feedback,content}' \
        "${ceiling_traj[@]}" 2>/dev/null || true
fi

# --- case 4: without beacon stamps the same block dies, as it used to --------
# Proves the case 2 result comes from the beacon and not from a slow watchdog.
fence 'shellm -q --max-iterations 1 "sub task" > sub.txt 2>&1; echo "sub done"' > "$WORK/script/1"
printf '9' > "$WORK/script/2.sleep"
fence 'FINAL=sub-answer' > "$WORK/script/2"
fence 'FINAL=done' > "$WORK/script/last"
SHELLM_BEACON_INTERVAL=600 SHELLM_INACTIVITY_TIMEOUT=3 SHELLM_INACTIVITY_MAX=600 \
    run_shellm "unbeaconed case"
if grep -q 'shellm-watchdog\] idle timeout' "$WORK/err"; then
    ok "nested run with no beacon stamps still dies at the idle timeout"
else
    bad "nested run with no beacon stamps still dies at the idle timeout" "$(tail -3 "$WORK/err")"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
