#!/usr/bin/env bash
# test_shellm_context_scope.sh — what the model sees of the trajectory
#
# Usage: tests/test_shellm_context_scope.sh
#
# Why: bin/context cut every field over 2048 bytes, the prompt step included,
# so a shellm run with a long prompt sent the model the first and last KB of
# its instructions and a stub saying "read with: traj show --full". Audel's
# monolith ran for months on the identity intro and the goals list, never
# seeing the routing signals or the function menu (2026-09-03). This runs
# shellm with a stubbed llm that records the messages it was sent, and checks:
# the prompt reaches the model whole in both scopes; --context-scope run
# sends only this run's steps with no history from earlier runs in the same
# trajectory; the default traj scope still carries the earlier run.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

# --- llm stub: records the --messages-file of every main-loop call -----------
mkdir -p "$WORK/home" "$WORK/wd" "$WORK/msgs"
cp -R "$REPO/bin" "$WORK/toolbin"
cat > "$WORK/toolbin/llm" <<'STUB'
#!/usr/bin/env bash
main_loop=0; mf=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --thinking) main_loop=1; shift ;;
        --messages-file) mf="$2"; shift 2 ;;
        --system-prompt) sp="$2"; shift 2 ;;
        *) shift ;;
    esac
done
if [[ "$main_loop" -ne 1 ]]; then printf '{}\n'; exit 0; fi
n=$(ls "$LLM_STUB_DIR" | grep -c "^call-.*json$")
cp "$mf" "$LLM_STUB_DIR/call-$((n + 1)).json"
[[ -n "${sp:-}" ]] && printf '%s' "$sp" > "$LLM_STUB_DIR/call-$((n + 1)).system"
printf '```bash\nFINAL=done\n```\n'
STUB
chmod +x "$WORK/toolbin/llm"

export PATH="$WORK/toolbin:$PATH"
export HOME="$WORK/home"
export HEADLONG_HOME="$WORK/home/.headlong"
export ANTHROPIC_API_KEY="test-key"
export SHELLM_MODEL="test-model"
export SHELLM_ENV=local
export LLM_STUB_DIR="$WORK/msgs"
# An ambient trajectory variable (any run inside shellm leaves these set:
# SHELLM_TRAJ_DIR outranks TRAJ_DIR, which outranks HEADLONG_HOME) would
# send the stub runs into the caller's real log — the --resume arms would
# resume it, too. Neutralize all three before any nested exec.
unset TRAJ_DIR TRAJ_ID SHELLM_TRAJ_DIR

run_shellm() {
    ( cd "$WORK/wd" && "$WORK/toolbin/shellm" --workdir "$WORK/wd" --max-iterations 1 "$@" ) \
        > "$WORK/out" 2> "$WORK/err" < /dev/null
}

# Prompts over the 2048 byte field limit, with a marker in the middle that a
# head+tail cut would drop.
mk_prompt() {
    local file="$1" mark="$2"
    { printf 'HEAD '; head -c 3000 /dev/zero | tr '\0' 'x'; printf ' %s ' "$mark"
      head -c 3000 /dev/zero | tr '\0' 'y'; printf ' TAIL\n'; } > "$file"
}
mk_prompt "$WORK/p1.txt" "FIRST-RUN-MARKER"
mk_prompt "$WORK/p2.txt" "SECOND-RUN-MARKER"
mk_prompt "$WORK/p3.txt" "THIRD-RUN-MARKER"

last_msgs() { ls "$WORK/msgs"/call-*.json | sort -V | tail -1; }

# --- 1. first run, new trajectory, default scope ----------------------------
run_shellm --prompt-file "$WORK/p1.txt"; rc=$?
m1=$(last_msgs)
if [[ "$rc" -eq 0 && -n "$m1" ]] && grep -q 'FIRST-RUN-MARKER' "$m1" && ! grep -q 'truncated:' "$m1"; then
    ok "traj scope: a 6K prompt reaches the model whole (rc=$rc)"
else
    bad "traj scope: a 6K prompt reaches the model whole" "rc=$rc $(tail -2 "$WORK/err" | tr '\n' ' ')"
fi

# --- 2. second run in the same trajectory, run scope -------------------------
run_shellm --resume --context-scope run --prompt-file "$WORK/p2.txt"; rc=$?
m2=$(last_msgs)
if [[ "$rc" -eq 0 && "$m2" != "$m1" ]] && grep -q 'SECOND-RUN-MARKER' "$m2" \
   && ! grep -q -e 'FIRST-RUN-MARKER' -e 'steps elided' -e 'truncated:' "$m2" \
   && [[ "$(jq -r '.[0].role + " " + .[0].content[0:5]' "$m2")" == "user HEAD " ]]; then
    ok "run scope: only this run's prompt, whole, first, no earlier run and no marker"
else
    bad "run scope: only this run's prompt" "rc=$rc $(jq -r '.[] | .role + " " + (.content[0:24])' "$m2" 2>/dev/null | tr '\n' '|')"
fi

# --- 3. third run, default scope, still sees the earlier runs -----------------
run_shellm --resume --prompt-file "$WORK/p3.txt"; rc=$?
m3=$(last_msgs)
if [[ "$rc" -eq 0 && "$m3" != "$m2" ]] && grep -q 'THIRD-RUN-MARKER' "$m3" && grep -q 'SECOND-RUN-MARKER' "$m3" \
   && ! grep -q 'truncated:' "$m3"; then
    ok "traj scope: a resumed run still carries the earlier runs, prompts whole"
else
    bad "traj scope: a resumed run still carries the earlier runs" "rc=$rc"
fi

# --- 3b. the system prompt's context guideline only when a context was given --
# A caller with neither stdin context nor -f files (the monolith) saw the mind
# spend first commands probing an empty $CONTEXT.
sp3="${m3%.json}.system"
if [[ -f "$sp3" ]] && ! grep -q 'Always start by inspecting' "$sp3"; then
    ok "no context given: the system prompt omits the \$CONTEXT guideline"
else
    bad "no context given: the system prompt omits the \$CONTEXT guideline"
fi
printf 'some context\n' > "$WORK/ctx.txt"
run_shellm -f "$WORK/ctx.txt" --prompt-file "$WORK/p3.txt"; rc=$?
spf="$(last_msgs)"; spf="${spf%.json}.system"
if [[ "$rc" -eq 0 && -f "$spf" ]] && grep -q 'Always start by inspecting' "$spf"; then
    ok "a -f context brings the guideline back"
else
    bad "a -f context brings the guideline back" "rc=$rc"
fi

# --- 4. env form and a bad value ---------------------------------------------
SHELLM_CONTEXT_SCOPE=run run_shellm --resume --prompt-file "$WORK/p2.txt"; rc=$?
m4=$(last_msgs)
if [[ "$rc" -eq 0 && "$m4" != "$m3" ]] && ! grep -q 'THIRD-RUN-MARKER' "$m4"; then
    ok "SHELLM_CONTEXT_SCOPE=run works like the flag"
else
    bad "SHELLM_CONTEXT_SCOPE=run works like the flag" "rc=$rc"
fi
run_shellm --context-scope bogus "hello"; rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'context-scope must be traj or run' "$WORK/err"; then
    ok "a bad --context-scope value is refused"
else
    bad "a bad --context-scope value is refused" "rc=$rc $(tail -1 "$WORK/err")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
