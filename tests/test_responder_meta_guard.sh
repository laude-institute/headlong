#!/usr/bin/env bash
# Exercise the real responder step with a stubbed llm and a narrowly targeted
# jq fault injector. No provider or transport calls. The injector substitutes
# the aggregate written after a call, modelling an unreadable/short/corrupt
# record at the sync boundary (not a reproduction of filesystem exhaustion).
# Invalid metadata must not authorize another model call or claim a timeout.
set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID THINK_CONTEXT_TAIL 2>/dev/null
unset LLM_MAX_TOKENS LLM_MAX_TIME LLM_RETRIES RESPONDER_MAX_TOKENS RESPONDER_MAX_TIME 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
STEP="${RESPONDER_STEP:-$REPO/thinkers/responder/step}"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

command -v jq >/dev/null 2>&1 || { echo "FAIL jq not found"; exit 1; }

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT

ME=testid
THEM=fixture-peer
ID="$WORK/ident"
TRAJ_ID="cafe0000-0000-0000-0000-0000000000ac"
mkdir -p "$ID/memories" "$ID/trajectories/$TRAJ_ID" "$ID/run"
printf 'name=%s\ncreated=test\nroot_trajectory=%s\n' "$ME" "$TRAJ_ID" > "$ID/info.txt"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"

# --- llm stub -----------------------------------------------------------------
# STUB_MODE: reply (print $STUB_REPLY_FILE), truncated (print it, warn like
# bin/llm, write a usage record), timeout (fail like curl 28), fail (exit 1
# fast, as a refused schema would). Every call appends argv + the env it
# cares about to $STUB_CALLS.
mkdir -p "$WORK/stub"
cat > "$WORK/stub/llm" <<'STUB'
#!/usr/bin/env bash
# one line per call: the argv carries the system prompt (newlines), so it
# is flattened and put after the env
argv="$*"; argv="${argv//$'\n'/ }"
printf 'CALL env=LLM_MAX_TIME:%s,LLM_RETRIES:%s,LLM_MAX_TOKENS:%s argv=%s\n' "${LLM_MAX_TIME:-}" "${LLM_RETRIES:-}" "${LLM_MAX_TOKENS:-}" "$argv" >> "$STUB_CALLS"
usage() { [[ -n "${LLM_USAGE_FILE:-}" ]] && printf '%s' "$1" > "$LLM_USAGE_FILE"; }
case "${STUB_MODE:-reply}" in
    reply)
        usage '{"in_tok":120,"out_tok":40,"think_tok":10,"served_by":"Fireworks"}'
        cat "$STUB_REPLY_FILE" ;;
    truncated)
        usage '{"in_tok":120,"out_tok":8192,"think_tok":700,"served_by":"Wafer","truncated":true}'
        echo "llm: warning: output truncated at max_tokens=8192 (reasoning tokens count against it) — raise with -t" >&2
        cat "$STUB_REPLY_FILE" ;;
    timeout)
        echo "llm: error: curl error: curl: (28) Operation timed out after 180000 milliseconds with 3332792 bytes received" >&2
        exit 1 ;;
    truncated_empty)
        # bin/llm's real shape for a cap spent on reasoning or whitespace:
        # the warning, a usage record, then a nonzero exit with no text.
        usage '{"in_tok":90,"out_tok":8192,"think_tok":8192,"served_by":"Novita","truncated":true}'
        echo "llm: warning: output truncated at max_tokens=8192 (reasoning tokens count against it) — raise with -t" >&2
        echo "llm: error: empty response: stream ended without emitting anything" >&2
        exit 1 ;;
    fail)
        echo "llm: error: API error (HTTP 400): schema not supported" >&2
        exit 1 ;;
esac
STUB
chmod +x "$WORK/stub/llm"
export STUB_REPLY_FILE="$WORK/reply" STUB_CALLS="$WORK/calls"

ago() {
    date -u -v-"$1"S +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
        || date -u -d "$1 seconds ago" +%Y-%m-%dT%H:%M:%S.000Z
}
msg() {  # msg <id> <content>
    printf '{"step_id":"%s","type":"message","from":"%s","to":"%s","content":"%s","ts":"%s","source":"chat"}\n' \
        "$1" "$THEM" "$ME" "$2" "$(ago 5)" >> "$TRAJ"
}
run_step() {  # run_step <trigger id> [env assignments...]
    local trig; trig=$(grep -F "\"step_id\":\"$1\"" "$TRAJ" | head -1); shift
    : > "$STUB_CALLS"
    printf '%s' "$trig" | env \
        PATH="$WORK/stub:$REPO/bin:$REPO/tools:$PATH" \
        IDENTITY_DIR="$ID" IDENTITY_NAME="$ME" MEM_DIR="$ID/memories" \
        TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID" HOME="$WORK/home" \
        SHELLM_MODEL="stub-model" THINK_MODEL="stub-model" MONOLITH_REPLY_MODEL="stub-model" \
        THINK_CONTEXT_TAIL=20 RESPONDER_STRUCTURED=1 \
        RESPONDER_LOG_PROMPT=0 RESPONDER_PERSON_NOTES=0 "$@" \
        "$STEP" >> "$WORK/step.log" 2>&1
}
obs_for() {
    jq -c --arg t "$1" 'select(.type == "observation" and .source == "responder"
                              and (.trigger_step // "") == $t and (.decision // "") != "")' "$TRAJ" | tail -1
}
sent_for() {  # the message the step sent in reply to a trigger, if any
    jq -c --arg t "$1" 'select(.type == "message" and .from == "'"$ME"'" and (.reply_to // "") == $t)' "$TRAJ" | tail -1
}
field() { printf '%s' "$1" | jq -r "$2"; }

printf '{"step_id":"%s","type":"trajectory","ts":"%s"}\n' "$TRAJ_ID" "$(ago 999999)" > "$TRAJ"


# Only intercept _reply_llm's aggregate writer; every other jq is real.
export REAL_JQ
REAL_JQ=$(command -v jq)
export META_FIXTURE="$WORK/injected-meta" META_INJECTIONS="$WORK/injections"
cat > "$WORK/stub/jq" <<'STUB'
#!/usr/bin/env bash
for arg do
    if [[ "$arg" == *'$prev.llm_ms'* && "${INJECT_META:-0}" == 1 ]]; then
        printf "injected\n" >> "$META_INJECTIONS"
        cat "$META_FIXTURE"
        exit 0
    fi
done
exec "$REAL_JQ" "$@"
STUB
chmod +x "$WORK/stub/jq"

check_case() {
    local id="$1" mode="$2" inject="$3" expected_calls="$4" expected_failure="$5"
    local rc=0 n o
    msg "$id" "fixture request"
    : > "$META_INJECTIONS"
    STUB_MODE="$mode" INJECT_META="$inject" run_step "$id" || rc=$?
    n=$(grep -c '^CALL' "$STUB_CALLS")
    o=$(obs_for "$id")
    [[ "$rc" == 0 ]] && ok "$id step completes" || bad "$id step completes" "rc=$rc"
    [[ "$n" == "$expected_calls" ]] && ok "$id call count $expected_calls" || bad "$id call count" "expected $expected_calls got $n"
    if [[ "$expected_failure" == metadata ]]; then
        [[ "$(wc -l < "$META_INJECTIONS" | tr -d ' ')" == "$n" ]] &&
            ok "$id injected every aggregate" || bad "$id fault injector missed writer"
        printf '%s' "$o" | "$REAL_JQ" -e '
            .decision == "reply-failed" and .failure == "metadata"
            and .meta_error == true and (.timed_out != true)
            and (.llm_calls == null)
        ' >/dev/null 2>&1 && ok "$id names unknown metadata, not zero spend or timeout" || bad "$id metadata observation" "$o"
    else
        [[ "$(field "$o" .failure)" == "$expected_failure" ]] &&
            ok "$id failure=$expected_failure" || bad "$id failure" "$o"
    fi
    [[ -z "$(sent_for "$id")" ]] && ok "$id sends no reply" || bad "$id sent a reply"
}

# Valid controls: a fast schema refusal really can retry, a timeout cannot.
check_case schema-refusal fail 0 2 empty
check_case timeout timeout 0 1 timeout

# Each invalid record follows an actually timed-out structured call. Reading
# it as false/zero must not turn that timeout into a second provider request.
printf '%s' '{"llm_ms":3700,"llm_calls":3' > "$META_FIXTURE"
check_case short-json timeout 1 1 metadata
: > "$META_FIXTURE"
check_case empty-file timeout 1 1 metadata
printf '%s' '{}' > "$META_FIXTURE"
check_case missing-count timeout 1 1 metadata
printf '%s' '[]' > "$META_FIXTURE"
check_case array timeout 1 1 metadata
printf '%s' '{"llm_calls":1,"llm_ms":1,"timed_out":"true"}' > "$META_FIXTURE"
check_case string-flag timeout 1 1 metadata
printf '%s' '{"llm_calls":"1","llm_ms":1}' > "$META_FIXTURE"
check_case string-count timeout 1 1 metadata
printf '%s' '{"llm_calls":-1,"llm_ms":1}' > "$META_FIXTURE"
check_case negative-count timeout 1 1 metadata
printf '%s' '{"llm_calls":1,"llm_ms":1} {"llm_calls":2,"llm_ms":2}' > "$META_FIXTURE"
check_case multiple-records timeout 1 1 metadata

printf '%s' 'null' > "$META_FIXTURE"
check_case null timeout 1 1 metadata
printf '%s' '{"llm_calls":0,"llm_ms":1}' > "$META_FIXTURE"
check_case zero-count timeout 1 1 metadata
printf '%s' '{"llm_calls":1.5,"llm_ms":1}' > "$META_FIXTURE"
check_case fractional-count timeout 1 1 metadata
printf '%s' '{"llm_calls":1,"llm_ms":1,"truncated":1}' > "$META_FIXTURE"
check_case numeric-truncated timeout 1 1 metadata
printf '%s' '{"llm_calls":1,"llm_ms":"1"}' > "$META_FIXTURE"
check_case string-duration timeout 1 1 metadata

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
