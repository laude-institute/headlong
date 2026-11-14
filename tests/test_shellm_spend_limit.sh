#!/usr/bin/env bash
# tests/test_shellm_spend_limit.sh — when bin/llm stops at the spend limit
# (LLM_SPEND_LIMIT_USD, exit 3), bin/shellm says so in the run's trajectory.
#
# Usage: tests/test_shellm_spend_limit.sh
#
# A model call refused at the limit sends nothing, and the run cannot think
# again until the limit is raised. Without a trajectory entry the mind would
# only see itself go quiet. call_llm and note_spend_limit are extracted from
# bin/shellm (sourcing the whole script would run it) and exercised against a
# stub `llm` on PATH; traj is the real one from bin/.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/traj"
cat > "$tmp/bin/llm" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == --spend ]]; then
    printf '{"spent":25.01,"limit":25,"remaining":0,"window":"month","since":"2026-10-01T00:00:00Z"}\n'
    exit 0
fi
case "$LLM_STUB_MODE" in
    spend)  printf 'llm: error: spend limit reached: $25.01 of $25 this month; no request sent\n' >&2; exit 3 ;;
    failed) printf 'llm: error: API error (HTTP 500)\n' >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/llm"
export PATH="$tmp/bin:$REPO/bin:$PATH"
unset TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID IDENTITY_DIR IDENTITY_NAME

# run_call_llm MODE TRAJ_ID: call_llm the way run_loop does, inside a command
# substitution under bin/shellm's own `set -euo pipefail`, with the run's
# trajectory variables set as run_loop sets them.
run_call_llm() {
    LLM_STUB_MODE="$1" RUN_TRAJ_ID="$2" QUIET=1 SHELLM_MODEL=stub-model SHELLM_EFFORT=medium \
    SHELLM_MAX_TOKENS='' REPO="$REPO" TRAJ_ROOT="$tmp/traj" \
        bash -c '
            set -euo pipefail
            die() { echo "shellm: error: $*" >&2; exit 1; }
            for fn in note_spend_limit call_llm; do
                body=$(sed -n "/^$fn()/,/^}/p" "$REPO/bin/shellm")
                [[ "$(printf "%s" "$body" | tail -n 1)" == "}" ]] || { echo "test bug: could not extract $fn" >&2; exit 2; }
                eval "$body"
            done
            _run_traj_dir="$TRAJ_ROOT" _run_traj_id="$RUN_TRAJ_ID" _run_step_id="run-step-1"
            _response=$(call_llm "system prompt" "[]" "")
        ' 2>"$tmp/err"
}
new_traj() { TRAJ_DIR="$tmp/traj" traj new --slug "$1" | head -n 1; }
traj_file() { TRAJ_DIR="$tmp/traj" TRAJ_ID="$1" traj path; }

# --- 1. exit 3: the run dies, and the trajectory says why -------------------
id=$(new_traj spend)
run_call_llm spend "$id"; rc=$?
if [[ "$rc" -eq 1 ]] && grep -q 'llm failed (exit 3)' "$tmp/err"; then
    ok "a spend-limited call still fails the run"
else
    bad "a spend-limited call still fails the run" "rc=$rc $(cat "$tmp/err")"
fi
obs=$(jq -c 'select(.type == "observation" and .decision == "spend-limit")' "$(traj_file "$id")" 2>/dev/null | tail -n 1)
if [[ -n "$obs" ]]; then
    ok "an observation with decision spend-limit is appended"
else
    bad "an observation with decision spend-limit is appended" "$(cat "$(traj_file "$id")")"
fi
want='{"spent":25.01,"limit":25,"window":"month"}'
got=$(printf '%s' "$obs" | jq -c '.spend')
[[ "$got" == "$want" ]] && ok "it carries the numbers from llm --spend" || bad "it carries the numbers from llm --spend" "want $want, got $got"
if printf '%s' "$obs" | jq -e '.content | test("spend limit reached: \\$25.01 of \\$25 this month") and test("LLM_SPEND_LIMIT_USD")' >/dev/null; then
    ok "its content tells the mind what happened and what to change"
else
    bad "its content tells the mind what happened and what to change" "$obs"
fi
[[ "$(printf '%s' "$obs" | jq -r '[.source, .run_id] | @tsv')" == $'shellm\trun-step-1' ]] \
    && ok "it names shellm and the run" || bad "it names shellm and the run" "$obs"

# --- 2. any other failure leaves no such entry ----------------------------------
id=$(new_traj other)
run_call_llm failed "$id"; rc=$?
if [[ "$rc" -eq 1 ]] && ! grep -q '"spend-limit"' "$(traj_file "$id")" 2>/dev/null; then
    ok "another llm failure records no spend-limit entry"
else
    bad "another llm failure records no spend-limit entry" "rc=$rc"
fi

echo
echo "passed: $pass"
echo "failed: $fail"
[[ "$fail" -eq 0 ]]
