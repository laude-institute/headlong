#!/usr/bin/env bash
# tests/test_responder_deferral.sh — deferrals that bind the mind
# (design/conversation_memory.md, part 5).
#
# Usage: tests/test_responder_deferral.sh
#
# The responder has no tools. When the model answers "DEFER: <work>" on the
# first line, the step must send the holding message below it, append an
# `action` step (source responder, trigger_step, person, request) that the
# monolith routes on, and mark its observation deferred. The monolith step
# must then show a PENDING REQUEST routing hint naming the exact follow-up
# command until an observation carries resolves=<trigger>. `chat reply
# --follow-up` must deliver a second reply to an already answered message,
# which the duplicate guard otherwise refuses. Stubbed llm and shellm; no LLM
# calls, no docker.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID THINK_CONTEXT_TAIL THINK_MODEL MONOLITH_REPLY_MODEL 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
RESPONDER="$REPO/thinkers/responder/step"
MONOLITH="$REPO/thinkers/monolith/step"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

command -v jq >/dev/null 2>&1 || { echo "FAIL jq not found"; exit 1; }

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT

ME=testid
THEM=andy
ID="$WORK/ident"
TRAJ_ID="cafe0000-0000-0000-0000-0000000000de"
mkdir -p "$ID/memories" "$ID/trajectories/$TRAJ_ID" "$ID/run"
printf 'name=%s\ncreated=test\nroot_trajectory=%s\n' "$ME" "$TRAJ_ID" > "$ID/info.txt"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"
printf 'test-token\n' > "$ID/run/dispatcher.token"

mkdir -p "$WORK/stub"
cat > "$WORK/stub/llm" <<'STUB'
#!/usr/bin/env bash
# Records every call's args; refuses the schema flag when STUB_SCHEMA_FAIL=1
# (a provider without structured output); answers with STUB_REPLY_FILE.
_model=""; _schema=0; _prev=""
for _a in "$@"; do [[ "$_prev" == "-m" ]] && _model="$_a"; [[ "$_a" == "--json-schema" ]] && _schema=1; _prev="$_a"; done
printf 'CALL model=%s schema=%s\n' "$_model" "$_schema" >> "${STUB_ARGS_FILE:-/dev/null}"
if [[ "${STUB_SCHEMA_FAIL:-0}" == "1" && "$_schema" == "1" ]]; then
    echo "stub: response_format not supported" >&2; exit 1
fi
cat "$STUB_REPLY_FILE"
STUB
cat > "$WORK/stub/shellm" <<'STUB'
#!/usr/bin/env bash
prev=""
for a in "$@"; do [[ "$prev" == "--prompt-file" ]] && cp "$a" "$STUB_CAPTURE"; prev="$a"; done
exit 0
STUB
chmod +x "$WORK/stub/llm" "$WORK/stub/shellm"
export STUB_REPLY_FILE="$WORK/reply" STUB_CAPTURE="$WORK/prompt" STUB_ARGS_FILE="$WORK/llm-args"

ENV_COMMON=(PATH="$WORK/stub:$REPO/bin:$REPO/tools:$PATH" IDENTITY_DIR="$ID" IDENTITY_NAME="$ME"
    MEM_DIR="$ID/memories" TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID" HOME="$WORK/home"
    SHELLM_MODEL=stub-model THINK_CONTEXT_TAIL=30 RESPONDER_PERSON_NOTES=0 MONOLITH_TIERED_MEMORY=0)
run_responder() { printf '%s' "$1" | env "${ENV_COMMON[@]}" "$RESPONDER" >> "$WORK/step.log" 2>&1; }
# Structured mode: a reply model whose provider enforces a JSON Schema.
run_responder_s() { : > "$STUB_ARGS_FILE"; printf '%s' "$1" | env "${ENV_COMMON[@]}" MONOLITH_REPLY_MODEL=deepseek/stub-pro "${@:2}" "$RESPONDER" >> "$WORK/step.log" 2>&1; }
last_llm_args() { grep "^CALL " "$STUB_ARGS_FILE" | tail -n 1; }
run_monolith()  { printf '%s' "$1" | env "${ENV_COMMON[@]}" MONOLITH_SHARE_HINT_EVERY=0 "$MONOLITH" >> "$WORK/step.log" 2>&1; }
now() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }

# --- 1. a DEFER reply: holding message + action + deferred observation -------
: > "$TRAJ"
printf '{"step_id":"hdr","type":"trajectory","ts":"%s"}\n' "$(now)" >> "$TRAJ"
printf '{"step_id":"trig-1","type":"message","from":"%s","to":"%s","content":"how is the bridge work going?","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf 'DEFER: check the telegram bridge work status and report it\nLet me look into that and get back to you.\n' > "$STUB_REPLY_FILE"
run_responder "$(grep -F '"step_id":"trig-1"' "$TRAJ")"

sent=$(jq -c 'select(.type=="message" and .from=="testid" and .reply_to=="trig-1")' "$TRAJ" | tail -1)
if [[ "$(printf '%s' "$sent" | jq -r .content)" == "Let me look into that and get back to you." ]]; then
    ok "the holding message below DEFER is what gets sent"
else
    bad "the holding message below DEFER is what gets sent" "got $sent"
fi
act=$(jq -c 'select(.type=="action" and .source=="responder")' "$TRAJ" | tail -1)
if [[ -n "$act" && "$(printf '%s' "$act" | jq -r .trigger_step)" == trig-1 \
      && "$(printf '%s' "$act" | jq -r .person)" == "$THEM" \
      && "$(printf '%s' "$act" | jq -r .request)" == "check the telegram bridge work status and report it" ]]; then
    ok "an action step carries trigger_step, person, and the request"
else
    bad "an action step carries trigger_step, person, and the request" "got $act"
fi
if printf '%s' "$act" | jq -e '.content | contains("chat reply --follow-up --reply-to trig-1 andy") and contains("resolves=trig-1")' >/dev/null 2>&1; then
    ok "the action names the exact delivery command"
else
    bad "the action names the exact delivery command" "got $(printf '%s' "$act" | jq -r .content)"
fi
act_line=$(grep -n '"type":"action"' "$TRAJ" | cut -d: -f1 | tail -1)
msg_line=$(grep -n '"reply_to":"trig-1"' "$TRAJ" | cut -d: -f1 | tail -1)
[[ "$act_line" -lt "$msg_line" ]] && ok "the action is appended before the holding message" || bad "the action is appended before the holding message" "action line $act_line, message line $msg_line"
obs=$(jq -c 'select(.type=="observation" and .source=="responder" and .trigger_step=="trig-1")' "$TRAJ" | tail -1)
if [[ "$(printf '%s' "$obs" | jq -r .decision)" == replied && "$(printf '%s' "$obs" | jq -r .deferred)" == true \
      && "$(printf '%s' "$obs" | jq -r .context_msgs)" =~ ^[0-9]+$ ]]; then
    ok "the observation is replied + deferred, with the metrics"
else
    bad "the observation is replied + deferred, with the metrics" "got $obs"
fi

# --- 2. the monolith sees a PENDING REQUEST hint until it is resolved --------
rm -f "$STUB_CAPTURE"
run_monolith "$act"
if grep -q 'PENDING REQUEST from andy: check the telegram bridge work status' "$STUB_CAPTURE" 2>/dev/null \
   && grep -q 'chat reply --follow-up --reply-to trig-1 andy' "$STUB_CAPTURE" \
   && grep -q -- '--field resolves=trig-1' "$STUB_CAPTURE"; then
    ok "the monolith prompt shows the pending request with the delivery command"
else
    bad "the monolith prompt shows the pending request with the delivery command" "$(grep -o 'PENDING[^\n]*' "$STUB_CAPTURE" 2>/dev/null | head -1)"
fi
if grep -q 'pending request' "$REPO/thinkers/monolith/prompt.md" && grep -q -- '--follow-up' "$REPO/thinkers/monolith/prompt.md"; then
    ok "the monolith prompt allows the one reply exception"
else
    bad "the monolith prompt allows the one reply exception"
fi
if grep -q 'outranks the rest of this menu' "$REPO/thinkers/monolith/prompt.md" \
   && grep -q 'unless you have a good reason not to' "$REPO/thinkers/monolith/prompt.md" \
   && grep -q 'names the reason and what would unblock it' "$REPO/thinkers/monolith/prompt.md"; then
    ok "the monolith prompt ranks a pending request first, with a stated-reason escape hatch"
else
    bad "the monolith prompt ranks a pending request first, with a stated-reason escape hatch"
fi
if grep -q 'Strongly prefer doing this work now (act), timer wake or not' "$STUB_CAPTURE" 2>/dev/null \
   && grep -q 'If you have a good reason not to this wake, append a thought saying why' "$STUB_CAPTURE" 2>/dev/null; then
    ok "the hint says to strongly prefer acting, or to say why not"
else
    bad "the hint says to strongly prefer acting, or to say why not"
fi

# --- 2b. every open request stays visible: an older one is not masked by a
# newer one, and none ages out of the recent-stream window (Audel, 2026-09-02:
# a request was hidden behind a newer one, then scrolled out of the 20-step
# window and was never delivered) ------------------------------------------
printf '{"step_id":"trig-1b","type":"message","from":"bob","to":"%s","content":"can you check the deploy?","ts":"%s","source":"chat"}\n' "$ME" "$(now)" >> "$TRAJ"
env "${ENV_COMMON[@]}" traj append --field type=action --field source=responder --field trigger_step=trig-1b \
    --field person=bob --field request="check the deploy status" --field content="Pending request from bob: check the deploy status." >/dev/null
i=0
while [[ $i -lt 40 ]]; do
    env "${ENV_COMMON[@]}" traj append --field type=thought --field content="filler thought $i" >/dev/null
    i=$((i+1))
done
# a request from long ago, written straight to the log so its ts is old
printf '{"step_id":"act-old","type":"action","source":"responder","trigger_step":"trig-old","person":"carol","request":"find that old paper","content":"Pending request from carol: find that old paper.","ts":"2020-01-01T00:00:00.000Z"}\n' >> "$TRAJ"
rm -f "$STUB_CAPTURE"
run_monolith '{"type":"monolith-wake","content":"wake","source":"monolith-timer"}'
andy_line=$(grep -n 'PENDING REQUEST from andy' "$STUB_CAPTURE" 2>/dev/null | head -1 | cut -d: -f1)
bob_line=$(grep -n 'PENDING REQUEST from bob: check the deploy status' "$STUB_CAPTURE" 2>/dev/null | head -1 | cut -d: -f1)
if [[ -n "$andy_line" && -n "$bob_line" ]]; then
    ok "both open requests show after 40 later steps buried them"
else
    bad "both open requests show after 40 later steps buried them" "andy=${andy_line:-none} bob=${bob_line:-none}"
fi
[[ -n "$andy_line" && -n "$bob_line" && "$andy_line" -lt "$bob_line" ]] && ok "the oldest request is listed first" || bad "the oldest request is listed first"
grep -q 'PENDING REQUEST from andy: [^(]*(pending for [0-9]* min)' "$STUB_CAPTURE" 2>/dev/null && ok "each request shows its age" || bad "each request shows its age" "$(grep -o 'PENDING REQUEST from andy[^.]*' "$STUB_CAPTURE" | head -1)"
if ! grep -q 'PENDING REQUEST from carol' "$STUB_CAPTURE" 2>/dev/null; then
    ok "a request older than the max age is not listed"
else
    bad "a request older than the max age is not listed"
fi
rm -f "$STUB_CAPTURE"
printf '{"type":"monolith-wake","content":"wake","source":"monolith-timer"}' | env "${ENV_COMMON[@]}" MONOLITH_SHARE_HINT_EVERY=0 MONOLITH_PENDING_MAX_AGE=3000d "$MONOLITH" >> "$WORK/step.log" 2>&1
if grep -q 'PENDING REQUEST from carol: find that old paper (pending for [0-9]* d, OVERDUE' "$STUB_CAPTURE" 2>/dev/null; then
    ok "a request past the overdue line says so"
else
    bad "a request past the overdue line says so" "$(grep -o 'PENDING REQUEST from carol[^.]*' "$STUB_CAPTURE" | head -1)"
fi
n=$(env "${ENV_COMMON[@]}" chat pending --json | jq 'length')
[[ "$n" == 3 ]] && ok "chat pending --json lists every unresolved request" || bad "chat pending --json lists every unresolved request" "got $n"
n=$(env "${ENV_COMMON[@]}" chat pending --max-age 30d --json | jq 'length')
[[ "$n" == 2 ]] && ok "chat pending --max-age drops old requests" || bad "chat pending --max-age drops old requests" "got $n"
first=$(env "${ENV_COMMON[@]}" chat pending | head -1)
[[ "$first" == *"carol: find that old paper (pending "*"trigger trig-old)" ]] && ok "chat pending text lines carry person, request, age, trigger" || bad "chat pending text lines carry person, request, age, trigger" "got '$first'"

# the mind delivers: follow-up reply to an already answered trigger
if printf 'The bridge work is half done: file sends work, photos next.' \
     | env "${ENV_COMMON[@]}" chat reply --follow-up --reply-to trig-1 "$THEM" 2>>"$WORK/step.log"; then
    ok "chat reply --follow-up sends a second reply to an answered message"
else
    bad "chat reply --follow-up sends a second reply to an answered message" "$(tail -2 "$WORK/step.log")"
fi
n=$(jq -c 'select(.type=="message" and .from=="testid" and .reply_to=="trig-1")' "$TRAJ" | wc -l | tr -d ' ')
fu=$(jq -c 'select(.type=="message" and .from=="testid" and .reply_to=="trig-1" and .follow_up==true)' "$TRAJ" | wc -l | tr -d ' ')
[[ "$n" == 2 && "$fu" == 1 ]] && ok "the follow-up is stamped reply_to and follow_up:true" || bad "the follow-up is stamped reply_to and follow_up:true" "replies=$n follow_up=$fu"
if ! printf 'dup' | env "${ENV_COMMON[@]}" chat reply --reply-to trig-1 "$THEM" 2>/dev/null; then
    bad "a plain second reply is still refused by the guard" "chat exited nonzero"
else
    n2=$(jq -c 'select(.type=="message" and .from=="testid" and .reply_to=="trig-1")' "$TRAJ" | wc -l | tr -d ' ')
    [[ "$n2" == 2 ]] && ok "a plain second reply is still refused by the guard" || bad "a plain second reply is still refused by the guard" "now $n2 replies"
fi

# resolving observations clear the hint, one request at a time
env "${ENV_COMMON[@]}" traj append --field type=observation --field content="Delivered the bridge status to andy." --field source=monolith --field resolves=trig-1 >/dev/null
rm -f "$STUB_CAPTURE"
run_monolith '{"type":"monolith-wake","content":"wake","source":"monolith-timer"}'
if ! grep -q 'PENDING REQUEST from andy' "$STUB_CAPTURE" 2>/dev/null && grep -q 'PENDING REQUEST from bob' "$STUB_CAPTURE" 2>/dev/null; then
    ok "an observation with resolves=<trigger> clears that request and leaves the others"
else
    bad "an observation with resolves=<trigger> clears that request and leaves the others" "$(grep -o 'PENDING REQUEST from [a-z]*' "$STUB_CAPTURE" | sort -u | tr '\n' ' ')"
fi
env "${ENV_COMMON[@]}" traj append --field type=observation --field content="Told bob the deploy is green." --field source=monolith --field resolves=trig-1b >/dev/null
rm -f "$STUB_CAPTURE"
run_monolith '{"type":"monolith-wake","content":"wake","source":"monolith-timer"}'
if ! grep -q 'PENDING REQUEST' "$STUB_CAPTURE" 2>/dev/null; then
    ok "resolving the last open request clears the hint"
else
    bad "resolving the last open request clears the hint"
fi

# --- 3. a normal reply appends no action ------------------------------------
printf '{"step_id":"trig-2","type":"message","from":"%s","to":"%s","content":"thanks!","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf 'Any time.\n' > "$STUB_REPLY_FILE"
run_responder "$(grep -F '"step_id":"trig-2"' "$TRAJ")"
acts=$(jq -c 'select(.type=="action" and .source=="responder")' "$TRAJ" | wc -l | tr -d ' ')
[[ "$acts" == 3 ]] && ok "a normal reply appends no action"   # the three deferrals above, none new || bad "a normal reply appends no action" "actions=$acts"
obs=$(jq -c 'select(.type=="observation" and .source=="responder" and .trigger_step=="trig-2")' "$TRAJ" | tail -1)
[[ "$(printf '%s' "$obs" | jq 'has("deferred")')" == false ]] && ok "a normal reply is not marked deferred" || bad "a normal reply is not marked deferred"

# --- 4. DEFER with nothing under it gets the default holding line -----------
printf '{"step_id":"trig-3","type":"message","from":"%s","to":"%s","content":"what is in the latest commit?","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf 'DEFER: read the latest commit and summarize it\n' > "$STUB_REPLY_FILE"
run_responder "$(grep -F '"step_id":"trig-3"' "$TRAJ")"
sent=$(jq -r 'select(.type=="message" and .from=="testid" and .reply_to=="trig-3") | .content' "$TRAJ" | tail -1)
[[ "$sent" == "Let me look into that and get back to you." ]] && ok "a bare DEFER sends the default holding line" || bad "a bare DEFER sends the default holding line" "got '$sent'"

# --- 5. a leading blank line does not hide the DEFER (Nemotron, 2026-09-10) --
printf '{"step_id":"trig-4","type":"message","from":"%s","to":"%s","content":"any conflicts in your workspace?","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf '\nDEFER: check the workspace for test goal conflicts\n' > "$STUB_REPLY_FILE"
run_responder "$(grep -F '"step_id":"trig-4"' "$TRAJ")"
sent=$(jq -r 'select(.type=="message" and .from=="testid" and .reply_to=="trig-4") | .content' "$TRAJ" | tail -1)
[[ "$sent" == "Let me look into that and get back to you." ]] && ok "a DEFER after a blank line sends the holding line, not the DEFER text" || bad "a DEFER after a blank line sends the holding line, not the DEFER text" "got '$sent'"
act=$(jq -c 'select(.type=="action" and .source=="responder" and .trigger_step=="trig-4")' "$TRAJ" | tail -1)
[[ -n "$act" && "$(printf '%s' "$act" | jq -r .request)" == "check the workspace for test goal conflicts" ]] && ok "a DEFER after a blank line still appends the action" || bad "a DEFER after a blank line still appends the action" "got '$act'"

# --- 6. DEFER emitted twice, holding text glued onto the first copy
#        (Nemotron, 2026-09-14: line 2 "DEFER: ..." was sent to Nick) --------
printf '{"step_id":"trig-5","type":"message","from":"%s","to":"%s","content":"can you please open a PR on github?","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf 'DEFER: open a PR for commit 1adc15cLet me open that PR for you.\nDEFER: open a PR for commit 1adc15c\n' > "$STUB_REPLY_FILE"
run_responder "$(grep -F '"step_id":"trig-5"' "$TRAJ")"
sent=$(jq -r 'select(.type=="message" and .from=="testid" and .reply_to=="trig-5") | .content' "$TRAJ" | tail -1)
[[ "$sent" == "Let me look into that and get back to you." ]] && ok "a duplicated DEFER never reaches the person" || bad "a duplicated DEFER never reaches the person" "got '$sent'"
act=$(jq -c 'select(.type=="action" and .source=="responder" and .trigger_step=="trig-5")' "$TRAJ" | tail -1)
[[ -n "$act" && "$(printf '%s' "$act" | jq -r .request)" == "open a PR for commit 1adc15c" ]] && ok "the clean copy of a glued DEFER becomes the request" || bad "the clean copy of a glued DEFER becomes the request" "got '$act'"

# --- 7. holding text first, DEFER on a later line ---------------------------
printf '{"step_id":"trig-6","type":"message","from":"%s","to":"%s","content":"what does the box say?","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf 'Let me check the box and get back to you.\nDEFER: read the box status and report it\n' > "$STUB_REPLY_FILE"
run_responder "$(grep -F '"step_id":"trig-6"' "$TRAJ")"
sent=$(jq -r 'select(.type=="message" and .from=="testid" and .reply_to=="trig-6") | .content' "$TRAJ" | tail -1)
[[ "$sent" == "Let me check the box and get back to you." ]] && ok "a DEFER on a later line is stripped and the holding text is sent" || bad "a DEFER on a later line is stripped and the holding text is sent" "got '$sent'"
act=$(jq -c 'select(.type=="action" and .source=="responder" and .trigger_step=="trig-6")' "$TRAJ" | tail -1)
[[ -n "$act" && "$(printf '%s' "$act" | jq -r .request)" == "read the box status and report it" ]] && ok "a DEFER on a later line still appends the action" || bad "a DEFER on a later line still appends the action" "got '$act'"

# --- 8. holding text glued in FRONT of the DEFER on one line, then repeated
#        (Nemotron, 2026-09-15 23:58Z: the whole line went to Slack) --------
printf '{"step_id":"trig-7","type":"message","from":"%s","to":"%s","content":"how do goals reach your wake prompt?","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf 'Let me look into the shellm architecture.DEFER: Investigate how goals are injected into the wake prompt\nLet me look into the shellm architecture.\n' > "$STUB_REPLY_FILE"
run_responder "$(grep -F '"step_id":"trig-7"' "$TRAJ")"
sent=$(jq -r 'select(.type=="message" and .from=="testid" and .reply_to=="trig-7") | .content' "$TRAJ" | tail -1)
[[ "$sent" == "Let me look into the shellm architecture." ]] && ok "a DEFER glued after prose is split off and the holding text is sent once" || bad "a DEFER glued after prose is split off and the holding text is sent once" "got '$sent'"
act=$(jq -c 'select(.type=="action" and .source=="responder" and .trigger_step=="trig-7")' "$TRAJ" | tail -1)
[[ -n "$act" && "$(printf '%s' "$act" | jq -r .request)" == "Investigate how goals are injected into the wake prompt" ]] && ok "a DEFER glued after prose still becomes the request" || bad "a DEFER glued after prose still becomes the request" "got '$act'"

# --- 9. talking ABOUT the protocol is not using it --------------------------
printf '{"step_id":"trig-8","type":"message","from":"%s","to":"%s","content":"what was that plumbing you mentioned?","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf 'My outgoing chat showed the raw DEFER: handoff text. I am tracing it.\n' > "$STUB_REPLY_FILE"
run_responder "$(grep -F '"step_id":"trig-8"' "$TRAJ")"
sent=$(jq -r 'select(.type=="message" and .from=="testid" and .reply_to=="trig-8") | .content' "$TRAJ" | tail -1)
[[ "$sent" == "My outgoing chat showed the raw DEFER: handoff text. I am tracing it." ]] && ok "a DEFER: after a space is prose and is sent as written" || bad "a DEFER: after a space is prose and is sent as written" "got '$sent'"
act=$(jq -c 'select(.type=="action" and .source=="responder" and .trigger_step=="trig-8")' "$TRAJ" | tail -1)
[[ -z "$act" ]] && ok "talking about DEFER appends no action" || bad "talking about DEFER appends no action" "got '$act'"

# --- 10. tool-call markup is never sent (Nemotron, 2026-09-15 DM) -----------
printf '{"step_id":"trig-9","type":"message","from":"%s","to":"%s","content":"which skills do you have?","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf '<function=skills>\n<parameter=command>\nshow\n</parameter>\n</function>\n' > "$STUB_REPLY_FILE"
run_responder "$(grep -F '"step_id":"trig-9"' "$TRAJ")"
sent=$(jq -r 'select(.type=="message" and .from=="testid" and .reply_to=="trig-9") | .content' "$TRAJ" | tail -1)
[[ -z "$sent" ]] && ok "tool-call markup is not sent to the person" || bad "tool-call markup is not sent to the person" "got '$sent'"
obs=$(jq -c 'select(.type=="observation" and .source=="responder" and .trigger_step=="trig-9")' "$TRAJ" | tail -1)
[[ -n "$obs" && "$(printf '%s' "$obs" | jq -r .decision)" == "reply-failed" ]] && ok "tool-call markup leaves a reply-failed observation for the mind" || bad "tool-call markup leaves a reply-failed observation for the mind" "got '$obs'"

# ===========================================================================
# Structured deferral (2026-09-16): on a model whose provider enforces a JSON
# Schema the reply is one object {action, message, request} and the decision
# is a required field. Everything below the parse is the text protocol.
# ===========================================================================

# --- 11. a structured reply -------------------------------------------------
printf '{"step_id":"trig-10","type":"message","from":"%s","to":"%s","content":"is the box up?","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf '{"action": "reply", "message": "Yes, all five units are active.", "request": ""}\n' > "$STUB_REPLY_FILE"
run_responder_s "$(grep -F '"step_id":"trig-10"' "$TRAJ")"
sent=$(jq -r 'select(.type=="message" and .from=="testid" and .reply_to=="trig-10") | .content' "$TRAJ" | tail -1)
[[ "$sent" == "Yes, all five units are active." ]] && ok "structured: the message field is what gets sent" || bad "structured: the message field is what gets sent" "got '$sent'"
[[ "$(last_llm_args)" == "CALL model=deepseek/stub-pro schema=1" ]] && ok "structured: llm is called with the reply schema" || bad "structured: llm is called with the reply schema" "got '$(last_llm_args)'"
obs=$(jq -c 'select(.type=="observation" and .source=="responder" and .trigger_step=="trig-10")' "$TRAJ" | tail -1)
[[ "$(printf '%s' "$obs" | jq -r .structured)" == "true" ]] && ok "structured: the observation records the shape" || bad "structured: the observation records the shape" "got '$obs'"

# --- 12. a structured deferral -----------------------------------------------
printf '{"step_id":"trig-11","type":"message","from":"%s","to":"%s","content":"what does the log say?","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf '{"action": "defer", "message": "Let me read the log and get back to you.", "request": "read the dispatcher log and report the last error"}\n' > "$STUB_REPLY_FILE"
run_responder_s "$(grep -F '"step_id":"trig-11"' "$TRAJ")"
sent=$(jq -r 'select(.type=="message" and .from=="testid" and .reply_to=="trig-11") | .content' "$TRAJ" | tail -1)
[[ "$sent" == "Let me read the log and get back to you." ]] && ok "structured defer: the holding sentence is sent" || bad "structured defer: the holding sentence is sent" "got '$sent'"
act=$(jq -c 'select(.type=="action" and .source=="responder" and .trigger_step=="trig-11")' "$TRAJ" | tail -1)
[[ -n "$act" && "$(printf '%s' "$act" | jq -r .request)" == "read the dispatcher log and report the last error" ]] && ok "structured defer: the request field becomes the action" || bad "structured defer: the request field becomes the action" "got '$act'"

# --- 13. a structured no_reply ----------------------------------------------
printf '{"step_id":"trig-12","type":"message","from":"%s","to":"%s","content":"thanks!","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf '{"action": "no_reply", "message": "", "request": ""}\n' > "$STUB_REPLY_FILE"
run_responder_s "$(grep -F '"step_id":"trig-12"' "$TRAJ")"
sent=$(jq -r 'select(.type=="message" and .from=="testid" and .reply_to=="trig-12") | .content' "$TRAJ" | tail -1)
obs=$(jq -c 'select(.type=="observation" and .source=="responder" and .trigger_step=="trig-12")' "$TRAJ" | tail -1)
[[ -z "$sent" && "$(printf '%s' "$obs" | jq -r .decision)" == "no-reply" ]] && ok "structured no_reply: nothing is sent, decision recorded" || bad "structured no_reply: nothing is sent, decision recorded" "sent='$sent' obs='$obs'"

# --- 14. a fenced object still parses ---------------------------------------
printf '{"step_id":"trig-13","type":"message","from":"%s","to":"%s","content":"ping","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf '```json\n{"action": "reply", "message": "pong", "request": ""}\n```\n' > "$STUB_REPLY_FILE"
run_responder_s "$(grep -F '"step_id":"trig-13"' "$TRAJ")"
sent=$(jq -r 'select(.type=="message" and .from=="testid" and .reply_to=="trig-13") | .content' "$TRAJ" | tail -1)
[[ "$sent" == "pong" ]] && ok "structured: a code-fenced object is read" || bad "structured: a code-fenced object is read" "got '$sent'"

# --- 15. a model that ignored the format falls into the text parser ---------
printf '{"step_id":"trig-14","type":"message","from":"%s","to":"%s","content":"check the bridge","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf 'DEFER: check the slack bridge status\nOn it, back shortly.\n' > "$STUB_REPLY_FILE"
run_responder_s "$(grep -F '"step_id":"trig-14"' "$TRAJ")"
sent=$(jq -r 'select(.type=="message" and .from=="testid" and .reply_to=="trig-14") | .content' "$TRAJ" | tail -1)
act=$(jq -c 'select(.type=="action" and .source=="responder" and .trigger_step=="trig-14")' "$TRAJ" | tail -1)
[[ "$sent" == "On it, back shortly." && "$(printf '%s' "$act" | jq -r .request)" == "check the slack bridge status" ]] && ok "structured: non-JSON output still goes through the DEFER parser" || bad "structured: non-JSON output still goes through the DEFER parser" "sent='$sent' act='$act'"

# --- 16. a provider that refuses the schema: one retry as text ---------------
printf '{"step_id":"trig-15","type":"message","from":"%s","to":"%s","content":"you there?","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf 'Here.\n' > "$STUB_REPLY_FILE"
run_responder_s "$(grep -F '"step_id":"trig-15"' "$TRAJ")" STUB_SCHEMA_FAIL=1
sent=$(jq -r 'select(.type=="message" and .from=="testid" and .reply_to=="trig-15") | .content' "$TRAJ" | tail -1)
[[ "$sent" == "Here." ]] && ok "fallback: a refused schema call is retried as text and answered" || bad "fallback: a refused schema call is retried as text and answered" "got '$sent'"
[[ "$(grep -c '^CALL ' "$STUB_ARGS_FILE")" == "2" && "$(last_llm_args)" == *"schema=0" ]] && ok "fallback: exactly two calls, the second without the schema" || bad "fallback: exactly two calls, the second without the schema" "$(cat "$STUB_ARGS_FILE")"
obs=$(jq -c 'select(.type=="observation" and .source=="responder" and .trigger_step=="trig-15")' "$TRAJ" | tail -1)
[[ "$(printf '%s' "$obs" | jq -r .structured)" == "false" ]] && ok "fallback: the observation records the text shape" || bad "fallback: the observation records the text shape" "got '$obs'"

# --- 17. RESPONDER_STRUCTURED=0 forces text even on a schema model ----------
printf '{"step_id":"trig-16","type":"message","from":"%s","to":"%s","content":"still there?","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf 'Still here.\n' > "$STUB_REPLY_FILE"
run_responder_s "$(grep -F '"step_id":"trig-16"' "$TRAJ")" RESPONDER_STRUCTURED=0
[[ "$(last_llm_args)" == *"schema=0" ]] && ok "RESPONDER_STRUCTURED=0 never sends the schema" || bad "RESPONDER_STRUCTURED=0 never sends the schema" "got '$(last_llm_args)'"

# --- 18. the prompt carries the voice block and the matching protocol ------
printf '{"step_id":"trig-17","type":"message","from":"%s","to":"%s","content":"hi","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf '{"action": "reply", "message": "hi", "request": ""}\n' > "$STUB_REPLY_FILE"
run_responder_s "$(grep -F '"step_id":"trig-17"' "$TRAJ")" RESPONDER_LOG_PROMPT=1
plog=$(ls -t "$ID/run/logs/responder-prompts/"*.txt 2>/dev/null | head -1)
grep -q "No dashes of any kind" "$plog" && grep -q 'action "defer"' "$plog" && ! grep -q 'put `DEFER:' "$plog" \
    && ok "structured prompt: voice block present, JSON protocol, no DEFER-line instruction" || bad "structured prompt: voice block present, JSON protocol, no DEFER-line instruction" "$plog"
printf 'hi\n' > "$STUB_REPLY_FILE"
printf '{"step_id":"trig-18","type":"message","from":"%s","to":"%s","content":"hello","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf '%s' "$(grep -F '"step_id":"trig-18"' "$TRAJ")" | env "${ENV_COMMON[@]}" RESPONDER_LOG_PROMPT=1 "$RESPONDER" >> "$WORK/step.log" 2>&1
plog=$(ls -t "$ID/run/logs/responder-prompts/"*.txt 2>/dev/null | head -1)
grep -q "No dashes of any kind" "$plog" && grep -q 'put `DEFER:' "$plog" && ! grep -q 'action "defer"' "$plog" \
    && ok "text prompt: voice block present, DEFER-line protocol, no JSON instruction" || bad "text prompt: voice block present, DEFER-line protocol, no JSON instruction" "$plog"

# --- 19. two inbounds, same holding text inside the window: the second
#        still sends (the deferral holding line is deliberate, --force) ------
printf '{"step_id":"trig-19a","type":"message","from":"%s","to":"%s","content":"can you look at the grinder?","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf 'DEFER: check the grinder state and report\nWorking on it.\n' > "$STUB_REPLY_FILE"
run_responder "$(grep -F '"step_id":"trig-19a"' "$TRAJ")"
first=$(jq -r 'select(.type=="message" and .from=="testid" and .reply_to=="trig-19a") | .content' "$TRAJ" | tail -1)
[[ "$first" == "Working on it." ]] || { echo "SKIP second-holding-line test: first holding line missing" >> "$WORK/step.log"; }
printf '{"step_id":"trig-19b","type":"message","from":"%s","to":"%s","content":"also look at the lathe?","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf 'DEFER: check the lathe state and report\nWorking on it.\n' > "$STUB_REPLY_FILE"
run_responder "$(grep -F '"step_id":"trig-19b"' "$TRAJ")"
second=$(jq -r 'select(.type=="message" and .from=="testid" and .reply_to=="trig-19b") | .content' "$TRAJ" | tail -1)
[[ "$second" == "Working on it." ]] && ok "a second deferral holding line inside the window still sends (--force exemption)" || bad "a second deferral holding line inside the window still sends (--force exemption)" "got '$second'"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
