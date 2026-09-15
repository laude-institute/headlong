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
# A bounded producer that keeps writing for ~6s at ~20 KB/s: it never goes idle
# (size grows every watchdog tick), so only the size guard can stop it. With the
# guard at 50 KB it is killed part-way; without the guard it runs to completion
# and no watchdog line is emitted.
fence 'end=$((SECONDS+6)); while [ $SECONDS -lt $end ]; do printf "x%.0s" {1..1000}; echo; sleep 0.05; done' > "$WORK/script/1"
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

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
