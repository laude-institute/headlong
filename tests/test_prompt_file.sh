#!/usr/bin/env bash
# test_prompt_file.sh — `shellm --prompt-file FILE` takes the prompt from a file
#
# Usage: tests/test_prompt_file.sh
#
# Why: Linux caps one argv string at 128KB (MAX_ARG_STRLEN). A mature
# identity's monolith wakeup prompt (life summary + recent stream) passes
# that, and every run died with "Argument list too long" (rc=126) before it
# started; the step logged it as a silent idle. The monolith step now hands
# the prompt over as a file. This checks the option end to end with a
# stubbed llm: a 300KB prompt runs, its text reaches the trajectory's prompt
# step, the inline form of the same prompt fails on Linux (the bug this
# guards against), and the two error paths say something useful.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

# --- llm stub: every reply sets FINAL, so a run ends on its first turn ---------
mkdir -p "$WORK/home" "$WORK/wd"
cp -R "$REPO/bin" "$WORK/toolbin"
cat > "$WORK/toolbin/llm" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == "--thinking" ]] && main_loop=1; done
if [[ "${main_loop:-0}" -ne 1 ]]; then printf '{}\n'; exit 0; fi
printf '```bash\nFINAL=done\n```\n'
STUB
chmod +x "$WORK/toolbin/llm"

export PATH="$WORK/toolbin:$PATH"
export HOME="$WORK/home"
export HEADLONG_HOME="$WORK/home/.headlong"
# An inherited TRAJ_DIR (any run inside shellm) outranks HEADLONG_HOME in
# bin/shellm, so the stub runs would write into the caller's real trajectory.
unset TRAJ_DIR TRAJ_ID SHELLM_TRAJ_DIR
export ANTHROPIC_API_KEY="test-key"
export SHELLM_MODEL="test-model"
export SHELLM_ENV=local

run_shellm() {
    ( cd "$WORK/wd" && "$WORK/toolbin/shellm" --workdir "$WORK/wd" --max-iterations 1 "$@" ) \
        > "$WORK/out" 2> "$WORK/err" < /dev/null
}

# A prompt well over Linux's 128KB per-argument cap, with a marker that
# exists nowhere else so we can find it in the trajectory.
MARK="prompt-file-marker-$$-$RANDOM"
PROMPT="$WORK/big-prompt.txt"
{
    printf 'Task with marker %s.\n' "$MARK"
    head -c 300000 /dev/zero | tr '\0' 'x'
    printf '\n'
} > "$PROMPT"
size=$(wc -c < "$PROMPT" | tr -d ' ')

# --- 1. the big prompt runs via --prompt-file --------------------------------
run_shellm --prompt-file "$PROMPT"
rc=$?
if [[ "$rc" -eq 0 ]]; then
    ok "300KB prompt runs via --prompt-file (${size} bytes, rc=0)"
else
    bad "300KB prompt runs via --prompt-file" "rc=$rc: $(tail -2 "$WORK/err" | tr '\n' ' ')"
fi

if grep -rq "$MARK" "$HEADLONG_HOME" 2>/dev/null; then
    ok "prompt text reached the trajectory"
else
    bad "prompt text reached the trajectory"
fi

# --- 2. the same prompt inline fails on Linux (the bug being guarded) -------
if [[ "$(uname -s)" == "Linux" ]]; then
    run_shellm "$(cat "$PROMPT")"
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
        ok "same prompt inline fails on Linux (rc=$rc, argv cap)"
    else
        bad "same prompt inline fails on Linux" "unexpectedly ran"
    fi
else
    printf 'skip inline-argv failure check (not Linux: %s)\n' "$(uname -s)"
fi

# --- 3. error paths -----------------------------------------------------------
run_shellm --prompt-file "$PROMPT" "also inline"
if [[ $? -ne 0 ]] && grep -q 'cannot be used together' "$WORK/err"; then
    ok "--prompt-file plus inline prompt is refused"
else
    bad "--prompt-file plus inline prompt is refused" "$(tail -1 "$WORK/err")"
fi

run_shellm --prompt-file "$WORK/does-not-exist"
if [[ $? -ne 0 ]] && grep -q 'Prompt file not found' "$WORK/err"; then
    ok "missing prompt file is a clear error"
else
    bad "missing prompt file is a clear error" "$(tail -1 "$WORK/err")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
