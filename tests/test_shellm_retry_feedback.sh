#!/usr/bin/env bash
# test_shellm_retry_feedback.sh — run_loop's empty-response retry feeds
# thinking back safely.
#
# Usage: tests/test_shellm_retry_feedback.sh
#
# Three guards around the retry that #87 made reachable, checked end to end
# against a stubbed llm:
#   1. The fed-back thinking travels by file (--messages-file / --rawfile),
#      never as one argv string: Linux caps a single argv string at 128KB
#      and a full-budget thinking block passes that, so the retry (and any
#      long conversation) would die with E2BIG before the call.
#   2. llm's own stderr lines ("llm: warning: ...") are stripped from the
#      fed-back thinking; they are harness noise, not model reasoning.
#   3. SHELLM_EMPTY_RESPONSE_RETRIES caps the loop (default 8), so a
#      persistently empty provider ends the run instead of billing forever.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

# --- llm stub ----------------------------------------------------------------
# Main-loop calls carry --thinking; utility calls do not and get '{}'. Each
# main call is numbered via a counter file. The stub records the content of
# --messages-file to msgs-N.json and the longest single argv string it saw
# to argvmax, then behaves per LLM_STUB_MODE:
#   feedback:     call 1 emits thinking plus a warning line on stderr and no
#                 stdout; call 2 answers.
#   big:          call 1 emits >300KB of thinking; call 2 answers.
#   always_empty: every call is thinking-only.
mkdir -p "$WORK/home" "$WORK/wd"
cp -R "$REPO/bin" "$WORK/toolbin"
cat > "$WORK/toolbin/llm" <<'STUB'
#!/usr/bin/env bash
main_loop=0
msgs_file=""
prev=""
max=0
for a in "$@"; do
    [[ "$a" == "--thinking" ]] && main_loop=1
    [[ "$prev" == "--messages-file" ]] && msgs_file="$a"
    [[ "${#a}" -gt "$max" ]] && max="${#a}"
    prev="$a"
done
if [[ "$main_loop" -ne 1 ]]; then printf '{}\n'; exit 0; fi
[[ -f "$LLM_STUB_DIR/argvmax" ]] && read -r old < "$LLM_STUB_DIR/argvmax" || old=0
[[ "$max" -gt "$old" ]] && printf '%s\n' "$max" > "$LLM_STUB_DIR/argvmax"
n=0
[[ -f "$LLM_STUB_DIR/calls" ]] && read -r n < "$LLM_STUB_DIR/calls"
n=$((n + 1))
printf '%s\n' "$n" > "$LLM_STUB_DIR/calls"
[[ -n "$msgs_file" ]] && cp "$msgs_file" "$LLM_STUB_DIR/msgs-$n.json"
case "$LLM_STUB_MODE" in
    feedback)
        if [[ "$n" -eq 1 ]]; then
            printf 'Thinking: the budget ran out here\n' >&2
            printf 'llm: warning: output truncated at max_tokens=100 (reasoning tokens count against it) — raise with -t\n' >&2
            exit 0
        fi
        printf '```bash\nFINAL=done\n```\n' ;;
    big)
        if [[ "$n" -eq 1 ]]; then
            printf 'Thinking: BIGMARK-start\n' >&2
            head -c 300000 /dev/zero | tr '\0' 'y' >&2
            printf '\n' >&2
            exit 0
        fi
        printf '```bash\nFINAL=done\n```\n' ;;
    always_empty)
        printf 'Thinking: still out of budget\n' >&2
        exit 0 ;;
esac
STUB
chmod +x "$WORK/toolbin/llm"

export PATH="$WORK/toolbin:$PATH"
export HOME="$WORK/home"
export HEADLONG_HOME="$WORK/home/.headlong"
# An ambient trajectory variable (any run inside shellm leaves these set:
# SHELLM_TRAJ_DIR outranks TRAJ_DIR, which outranks HEADLONG_HOME) would
# send the stub runs into the caller's real log. Neutralize all three
# before any nested exec.
unset TRAJ_DIR TRAJ_ID SHELLM_TRAJ_DIR
export ANTHROPIC_API_KEY="test-key"
export SHELLM_MODEL="test-model"
export SHELLM_ENV=local

run_shellm() {
    local mode="$1"; shift
    rm -rf "$WORK/stub"; mkdir -p "$WORK/stub"
    LLM_STUB_DIR="$WORK/stub" LLM_STUB_MODE="$mode" \
        "$WORK/toolbin/shellm" --workdir "$WORK/wd" --max-iterations 1 "$@" "do the task" \
        > "$WORK/out" 2> "$WORK/err" < /dev/null
}
main_calls() { cat "$WORK/stub/calls" 2>/dev/null || echo 0; }

# --- 1. thinking is fed back as assistant content, minus harness lines -------
run_shellm feedback
rc=$?
if [[ "$rc" -eq 0 && "$(main_calls)" -eq 2 ]]; then
    ok "empty response retries once and the run completes (rc=0)"
else
    bad "empty response retries once and the run completes" "rc=$rc calls=$(main_calls): $(tail -2 "$WORK/err" | tr '\n' ' ')"
fi

if jq -e '[.[] | select(.role == "assistant")] | any(.content | contains("budget ran out here"))' \
        "$WORK/stub/msgs-2.json" >/dev/null 2>&1; then
    ok "retry carries the thinking as assistant content"
else
    bad "retry carries the thinking as assistant content" "$(cat "$WORK/stub/msgs-2.json" 2>/dev/null | head -c 300)"
fi

if jq -e '[.[] | select(.role == "assistant")] | any(.content | contains("llm: warning:"))' \
        "$WORK/stub/msgs-2.json" >/dev/null 2>&1; then
    bad "llm warning lines are kept out of the fed-back thinking"
else
    ok "llm warning lines are kept out of the fed-back thinking"
fi

# --- 2. a >128KB thinking block survives the round trip off argv -------------
run_shellm big
rc=$?
if [[ "$rc" -eq 0 && "$(main_calls)" -eq 2 ]]; then
    ok "300KB thinking block retries and completes (rc=0)"
else
    bad "300KB thinking block retries and completes" "rc=$rc calls=$(main_calls): $(tail -2 "$WORK/err" | tr '\n' ' ')"
fi

if jq -e '[.[] | select(.role == "assistant")] | any(.content | (contains("BIGMARK-start") and (length > 300000)))' \
        "$WORK/stub/msgs-2.json" >/dev/null 2>&1; then
    ok "the full thinking text reached the retry messages"
else
    bad "the full thinking text reached the retry messages"
fi

argvmax=$(cat "$WORK/stub/argvmax" 2>/dev/null || echo 0)
if [[ "$argvmax" -lt 131072 ]]; then
    ok "no single argv string neared Linux's 128KB cap (max ${argvmax} bytes)"
else
    bad "no single argv string neared Linux's 128KB cap" "max ${argvmax} bytes"
fi

# --- 3. the retry loop is capped ---------------------------------------------
SHELLM_EMPTY_RESPONSE_RETRIES=2 run_shellm always_empty
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'after 2 retries' "$WORK/err"; then
    ok "persistently empty responses end the run at the cap (rc=$rc)"
else
    bad "persistently empty responses end the run at the cap" "rc=$rc: $(tail -2 "$WORK/err" | tr '\n' ' ')"
fi

if grep -Eq 'SHELLM_EMPTY_RESPONSE_RETRIES[^ ]*-8' "$REPO/bin/shellm"; then
    ok "the cap has a finite default"
else
    bad "the cap has a finite default" "no default found on SHELLM_EMPTY_RESPONSE_RETRIES"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
