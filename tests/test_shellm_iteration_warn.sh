#!/usr/bin/env bash
# test_shellm_iteration_warn.sh — near a --max-iterations cap, shellm tells the
# model how many steps are left, so a capped run (project mode caps every wake)
# can record its work and set FINAL instead of being cut off mid-task.
#
# Usage: tests/test_shellm_iteration_warn.sh
#
# Against a stubbed llm that never sets FINAL: with --max-iterations 4 the
# first call carries no notice, the last SHELLM_ITERATION_WARN (3) calls do,
# with the right counts, appended to the last user turn; a run far from its cap
# sees no notice. No network, no docker.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

mkdir -p "$WORK/home" "$WORK/wd"
cp -R "$REPO/bin" "$WORK/toolbin"
cat > "$WORK/toolbin/llm" <<'STUB'
#!/usr/bin/env bash
main_loop=0 msgs_file="" prev=""
for a in "$@"; do
    [[ "$a" == "--thinking" ]] && main_loop=1
    [[ "$prev" == "--messages-file" ]] && msgs_file="$a"
    prev="$a"
done
if [[ "$main_loop" -ne 1 ]]; then printf '{}\n'; exit 0; fi
n=0
[[ -f "$LLM_STUB_DIR/calls" ]] && read -r n < "$LLM_STUB_DIR/calls"
n=$((n + 1))
printf '%s\n' "$n" > "$LLM_STUB_DIR/calls"
[[ -n "$msgs_file" ]] && cp "$msgs_file" "$LLM_STUB_DIR/msgs-$n.json"
if [[ "$LLM_STUB_MODE" == finish && "$n" -ge 2 ]]; then printf '```bash\nFINAL=done\n```\n'; exit 0; fi
printf '```bash\necho working %s\n```\n' "$n"
STUB
chmod +x "$WORK/toolbin/llm"

export PATH="$WORK/toolbin:$PATH"
export HOME="$WORK/home"
export HEADLONG_HOME="$WORK/home/.headlong"
export ANTHROPIC_API_KEY="test-key"
export SHELLM_MODEL="test-model"
export SHELLM_ENV=local

run_shellm() {
    local mode="$1"; shift
    rm -rf "$WORK/stub"; mkdir -p "$WORK/stub"
    LLM_STUB_DIR="$WORK/stub" LLM_STUB_MODE="$mode" \
        "$WORK/toolbin/shellm" --workdir "$WORK/wd" "$@" "do the task" \
        > "$WORK/out" 2> "$WORK/err" < /dev/null
}
note_in() { jq -r '[.[] | select(.role == "user") | .content | if type == "string" then . else tostring end] | last // ""' "$WORK/stub/msgs-$1.json" 2>/dev/null; }

run_shellm loop --max-iterations 4
rc=$?
[[ "$rc" -ne 0 ]] && ok "capped run without FINAL exits non-zero" || bad "capped run without FINAL exits non-zero"
calls=$(cat "$WORK/stub/calls" 2>/dev/null || echo 0)
[[ "$calls" -eq 4 ]] && ok "the cap holds (4 calls)" || bad "the cap holds" "calls=$calls"
if note_in 1 | grep -q 'harness: this is step'; then bad "no notice far from the cap"; else ok "no notice far from the cap"; fi
note_in 2 | grep -qF 'step 2 of at most 4 in this run (3 left' && ok "notice three steps out" || bad "notice three steps out" "$(note_in 2 | tail -c 300)"
note_in 4 | grep -qF 'step 4 of at most 4 in this run (1 left' && ok "notice on the last step" || bad "notice on the last step" "$(note_in 4 | tail -c 300)"
note_in 4 | grep -qF 'set FINAL with your handoff' && ok "notice says to set FINAL" || bad "notice says to set FINAL"
u=$(jq '[.[] | select(.role == "user")] | length' "$WORK/stub/msgs-3.json" 2>/dev/null)
a=$(jq '[.[] | select(.role == "assistant")] | length' "$WORK/stub/msgs-3.json" 2>/dev/null)
[[ "$u" -eq $((a + 1)) ]] && ok "notice joins the last user turn (no extra turn)" || bad "notice joins the last user turn" "user=$u assistant=$a"

run_shellm finish --max-iterations 10
rc=$?
[[ "$rc" -eq 0 ]] && ok "run that finishes well inside its cap succeeds" || bad "run that finishes well inside its cap succeeds" "rc=$rc"
if note_in 2 | grep -q 'harness: this is step'; then bad "no notice when far from the cap"; else ok "no notice when far from the cap"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
