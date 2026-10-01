#!/usr/bin/env bash
# tests/test_responder_reply_guard.sh — the bounds and guards on the
# responder's reply call (the 2026-09-21 dinner thread, bug 2).
#
# Usage: tests/test_responder_reply_guard.sh
#
# Drives thinkers/responder/step against a throwaway identity with a stubbed
# `llm` on PATH that records its argv and environment and answers from a
# file, or fails the way bin/llm fails. Real traj + chat from bin/. Checks:
#   - the reply call carries its own token cap and wall-clock cap
#     (RESPONDER_MAX_TOKENS / RESPONDER_MAX_TIME) and turns bin/llm's own
#     retries off, whatever the box .env says for the mind
#   - a structured object cut off outside a string is repaired and acted on
#   - one cut off inside its message is not sent as a fragment
#   - an object that cannot be repaired is never sent as text
#   - a timed-out call is not retried as plain text
#   - every decision observation carries llm_ms / llm_calls / out_tok and
#     every failure names its kind (failure: timeout|truncated|parse|...)
#   - a standalone <skills show ...> reply hands the original request to
#     the mind, while quoted commands, examples and ordinary prose pass

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID THINK_CONTEXT_TAIL 2>/dev/null
unset LLM_MAX_TOKENS LLM_MAX_TIME LLM_RETRIES RESPONDER_MAX_TOKENS RESPONDER_MAX_TIME 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
STEP="$REPO/thinkers/responder/step"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

command -v jq >/dev/null 2>&1 || { echo "FAIL jq not found"; exit 1; }

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT

ME=testid
THEM=slack-U0614H65RN3-C0BMVH6LM4K
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
        SHELLM_MODEL="stub-model" THINK_CONTEXT_TAIL=20 RESPONDER_STRUCTURED=1 \
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

# --- 1. the call is bounded on its own ------------------------------------
msg t1 "hello there"
printf '{"action":"reply","message":"Hi Andy."}' > "$STUB_REPLY_FILE"
STUB_MODE=reply run_step t1 LLM_MAX_TOKENS=65536 LLM_MAX_TIME=600
call=$(grep '^CALL' "$STUB_CALLS" | head -1 | cut -c1-200)
printf '%s' "$call" | grep -q -- '-t 8192' && ok "the reply call carries its own 8K token cap (not the mind's 65536)" || bad "token cap on argv" "$call"
printf '%s' "$call" | grep -q 'LLM_MAX_TIME:180,' && ok "the reply call carries its own 180 s wall clock cap (not the inherited 600)" || bad "wall clock cap" "$call"
printf '%s' "$call" | grep -q 'LLM_RETRIES:0,' && ok "bin/llm's own retries are off for the reply call" || bad "retries off" "$call"
o=$(obs_for t1)
[[ "$(field "$o" .decision)" == "replied" ]] && ok "the reply went out" || bad "replied" "$o"
[[ "$(field "$o" .llm_calls)" == "1" && "$(field "$o" .out_tok)" == "40" && "$(field "$o" .served_by)" == "Fireworks" ]] && ok "the observation carries llm_calls, out_tok and served_by from the call" || bad "call metrics" "$o"
[[ "$(field "$o" .llm_ms)" =~ ^[0-9]+$ && "$(field "$o" .parse)" == "structured" ]] && ok "and llm_ms + parse=structured" || bad "llm_ms/parse" "$o"

msg t1b "and again"
STUB_MODE=reply run_step t1b RESPONDER_MAX_TOKENS=4000 RESPONDER_MAX_TIME=60
grep -q -- '-t 4000' "$STUB_CALLS" && grep -q 'LLM_MAX_TIME:60,' "$STUB_CALLS" && ok "RESPONDER_MAX_TOKENS / RESPONDER_MAX_TIME override the caps" || bad "override knobs" "$(cat "$STUB_CALLS")"

# --- 2. a cut-off object is repaired when the cut is outside a string --------
msg t2 "are you there?"
printf '{"action":"no_reply","message":""\t          \t  \t  \t  ' > "$STUB_REPLY_FILE"
STUB_MODE=truncated run_step t2
o=$(obs_for t2)
[[ "$(field "$o" .decision)" == "no-reply" ]] && ok "the DeepSeek runaway shape (object then whitespace to the cap) is repaired and read as no_reply" || bad "salvage no_reply" "$o"
[[ -z "$(sent_for t2)" ]] && ok "nothing was sent to the person" || bad "nothing sent" "$(sent_for t2)"
[[ "$(field "$o" .truncated)" == "true" && "$(field "$o" .parse)" == "salvaged" ]] && ok "the observation says truncated + parse=salvaged" || bad "truncated flag" "$o"

msg t2b "what time?"
printf '{"action":"reply","message":"About nine.","request":"' > "$STUB_REPLY_FILE"
STUB_MODE=truncated run_step t2b
o=$(obs_for t2b)
[[ "$(field "$o" .decision)" == "reply-failed" && "$(field "$o" .failure)" == "parse" ]] && ok "an object cut inside a string (not no_reply) is not repaired: reply-failed, failure=parse" || bad "cut in string" "$o"
[[ -z "$(sent_for t2b)" ]] && ok "no fragment was sent" || bad "fragment sent" "$(sent_for t2b)"

# --- 3. an unrepairable object is never sent as text -------------------------
msg t3 "hey"
printf '{"action":"reply","messag' > "$STUB_REPLY_FILE"
STUB_MODE=reply run_step t3
o=$(obs_for t3)
[[ "$(field "$o" .decision)" == "reply-failed" && "$(field "$o" .failure)" == "parse" ]] && ok "a broken object leaves a reply-failed observation (failure=parse) for the mind" || bad "broken object" "$o"
[[ -z "$(sent_for t3)" ]] && ok "raw JSON never reaches the person" || bad "raw json sent" "$(sent_for t3)"

# --- 4. a timed-out call is not retried ---------------------------------------
msg t4 "stop stop stop"
STUB_MODE=timeout run_step t4
[[ $(grep -c '^CALL' "$STUB_CALLS") -eq 1 ]] && ok "a timed-out structured call is not retried as plain text" || bad "no retry after timeout" "$(cat "$STUB_CALLS")"
o=$(obs_for t4)
[[ "$(field "$o" .decision)" == "reply-failed" && "$(field "$o" .failure)" == "timeout" && "$(field "$o" .timed_out)" == "true" ]] && ok "the observation says failure=timeout, timed_out=true" || bad "timeout obs" "$o"
printf '%s' "$o" | jq -e '.content | test("longer than 180s")' >/dev/null && ok "and tells the mind how long it waited" || bad "timeout text" "$o"

# --- 5. a fast failure still falls back to plain text -------------------------
msg t5 "ping"
printf 'Pong.' > "$STUB_REPLY_FILE"
STUB_MODE=fail run_step t5 2>/dev/null
# the stub fails every call, so the fallback fails too; what matters is that it was tried
[[ $(grep -c '^CALL' "$STUB_CALLS") -eq 2 ]] && ok "a fast schema failure is retried once as plain text" || bad "fallback tried" "$(cat "$STUB_CALLS")"
o=$(obs_for t5)
[[ "$(field "$o" .decision)" == "reply-failed" && "$(field "$o" .llm_calls)" == "2" && "$(field "$o" .fallback)" == "true" ]] && ok "the observation counts both calls and marks the fallback" || bad "fallback obs" "$o"

# --- 6. truncated with nothing usable -----------------------------------------
msg t6 "you there?"
: > "$STUB_REPLY_FILE"
STUB_MODE=truncated run_step t6
o=$(obs_for t6)
[[ "$(field "$o" .decision)" == "reply-failed" && "$(field "$o" .failure)" == "truncated" ]] && ok "a call that spent the whole cap on nothing is reply-failed, failure=truncated" || bad "truncated empty" "$o"

# --- 7. a cap spent on nothing (nonzero exit) is final, like a timeout -------
msg t7 "hello?"
STUB_MODE=truncated_empty run_step t7
[[ $(grep -c '^CALL' "$STUB_CALLS") -eq 1 ]] && ok "a structured call that spent the cap with no text is not retried as plain text" || bad "no retry after truncation" "$(cat "$STUB_CALLS")"
o=$(obs_for t7)
[[ "$(field "$o" .decision)" == "reply-failed" && "$(field "$o" .failure)" == "truncated" && "$(field "$o" .served_by)" == "Novita" ]] && ok "the observation says failure=truncated and names the host" || bad "truncated obs" "$o"

# --- 8. skills command tags are a handoff, never a chat reply ---------------
action_for() {
    jq -c --arg t "$1" 'select(.type == "action" and .source == "responder"
                              and (.trigger_step // "") == $t)' "$TRAJ" | tail -1
}
command_tag_case() {  # command_tag_case <trigger> <reply> <structured>
    local t="$1" text="$2" mode="$3" sent act obs act_line sent_line
    msg "$t" "Please delegate the implementation to opencode."
    if [[ "$mode" == 1 ]]; then
        jq -nc --arg text "$text" '{action:"reply", message:$text, request:""}' > "$STUB_REPLY_FILE"
    else
        printf '%s' "$text" > "$STUB_REPLY_FILE"
    fi
    STUB_MODE=reply run_step "$t" RESPONDER_STRUCTURED="$mode"
    sent=$(sent_for "$t"); act=$(action_for "$t"); obs=$(obs_for "$t")
    [[ "$(field "$sent" .content)" == "Let me look into that and get back to you." ]] \
        && ok "$t: command tag is replaced by the holding message" || bad "$t: holding message" "$sent"
    [[ "$(field "$act" .request)" == "Please delegate the implementation to opencode." \
       && "$(field "$act" .person)" == "$THEM" ]] \
        && ok "$t: pending action keeps the original request and sender" || bad "$t: pending action" "$act"
    [[ "$(field "$obs" .decision)" == replied && "$(field "$obs" .deferred)" == true \
       && "$(field "$obs" .llm_calls)" == 1 ]] \
        && ok "$t: observation records the deferral and single model call" || bad "$t: deferral metrics" "$obs"
    act_line=$(grep -nF "\"trigger_step\":\"$t\"" "$TRAJ" | grep '"type":"action"' | cut -d: -f1 | tail -1)
    sent_line=$(grep -nF "\"reply_to\":\"$t\"" "$TRAJ" | cut -d: -f1 | tail -1)
    [[ -n "$act_line" && -n "$sent_line" && "$act_line" -lt "$sent_line" ]] \
        && ok "$t: pending action precedes the holding message" || bad "$t: action before reply"
    STUB_MODE=reply run_step "$t" RESPONDER_STRUCTURED="$mode"
    n=$(jq -s --arg t "$t" '[.[] | select(.type == "action" and .trigger_step == $t)] | length' "$TRAJ")
    replies=$(jq -s --arg t "$t" '[.[] | select(.type == "message" and .from == "testid" and .reply_to == $t)] | length' "$TRAJ")
    [[ ! -s "$STUB_CALLS" && "$n" == 1 && "$replies" == 1 ]] \
        && ok "$t: redelivery repeats neither the model call, action nor reply" || bad "$t: redelivery" "actions=$n replies=$replies"
}
command_tag_case tag-structured '<skills show opencode>' 1
command_tag_case tag-text '<skills show opencode>' 0
command_tag_case tag-whitespace $' \t\n<skills\tshow\topencode>\r\n ' 1

# Newlines are flattened into a single request; a DEFER mention in the
# user's text is data, not another handoff protocol emitted by the model.
jq -nc --arg from "$THEM" --arg to "$ME" --arg ts "$(ago 5)" \
    '{step_id:"tag-original", type:"message", from:$from, to:$to, ts:$ts,
      source:"chat", content:"Please use opencode.\nExplain DEFER: in the documentation."}' >> "$TRAJ"
printf '{"action":"reply","message":"<skills show opencode>"}' > "$STUB_REPLY_FILE"
STUB_MODE=reply run_step tag-original
act=$(action_for tag-original)
[[ "$(field "$act" .request)" == "Please use opencode. Explain DEFER: in the documentation." ]] \
    && ok "the original multiline request is handed off without reinterpreting DEFER" || bad "original request" "$act"

# A structured defer already carries a request; keep it when its holding
# message is another command tag rather than creating a second handoff.
msg tag-defer "Please delegate the implementation."
printf '{"action":"defer","request":"Implement the requested change using opencode.","message":"<skills show opencode>"}' > "$STUB_REPLY_FILE"
STUB_MODE=reply run_step tag-defer
sent=$(sent_for tag-defer); act=$(action_for tag-defer)
[[ "$(field "$sent" .content)" == "Let me look into that and get back to you." \
   && "$(field "$act" .request)" == "Implement the requested change using opencode." ]] \
    && ok "command tag in a holding message keeps the existing deferral" || bad "existing deferral" "$sent $act"
n=$(jq -c 'select(.type == "action" and .trigger_step == "tag-defer")' "$TRAJ" | wc -l | tr -d ' ')
[[ "$n" == 1 ]] && ok "the existing deferral is recorded once" || bad "single deferral" "got $n"

# Explicitly quoted commands and explanatory text remain useful replies.
i=0
for text in '`<skills show opencode>`' '"<skills show opencode>"' \
    $'```bash\n<skills show opencode>\n```' \
    'Use `skills show opencode` to read its instructions.' \
    '<skills show opencode> is the pseudo-command it returned.' \
    $'<skills show opencode>\nThis is an example, not a tool call.' \
    '<status>ready</status>' '<3'; do
    i=$((i + 1)); t="literal-$i"
    msg "$t" "Explain the command syntax."
    jq -nc --arg text "$text" '{action:"reply", message:$text, request:""}' > "$STUB_REPLY_FILE"
    STUB_MODE=reply run_step "$t"
    sent=$(sent_for "$t")
    [[ "$(field "$sent" .content)" == "$text" && -z "$(action_for "$t")" ]] \
        && ok "$t: quoted command, prose or example is sent unchanged" || bad "$t: literal reply" "$sent"
done

msg tool-markup "Please look up the instructions."
printf '{"action":"reply","message":"<function=skills>show opencode</function>"}' > "$STUB_REPLY_FILE"
STUB_MODE=reply run_step tool-markup
o=$(obs_for tool-markup)
[[ -z "$(sent_for tool-markup)" && "$(field "$o" .failure)" == markup ]] \
    && ok "the existing tool-call markup guard still rejects function calls" || bad "existing markup guard" "$o"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
