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
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID THINK_CONTEXT_TAIL 2>/dev/null

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
cat "$STUB_REPLY_FILE"
STUB
cat > "$WORK/stub/shellm" <<'STUB'
#!/usr/bin/env bash
prev=""
for a in "$@"; do [[ "$prev" == "--prompt-file" ]] && cp "$a" "$STUB_CAPTURE"; prev="$a"; done
exit 0
STUB
chmod +x "$WORK/stub/llm" "$WORK/stub/shellm"
export STUB_REPLY_FILE="$WORK/reply" STUB_CAPTURE="$WORK/prompt"

ENV_COMMON=(PATH="$WORK/stub:$REPO/bin:$REPO/tools:$PATH" IDENTITY_DIR="$ID" IDENTITY_NAME="$ME"
    MEM_DIR="$ID/memories" TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID" HOME="$WORK/home"
    SHELLM_MODEL=stub-model THINK_CONTEXT_TAIL=30 RESPONDER_PERSON_NOTES=0 MONOLITH_TIERED_MEMORY=0)
run_responder() { printf '%s' "$1" | env "${ENV_COMMON[@]}" "$RESPONDER" >> "$WORK/step.log" 2>&1; }
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

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
