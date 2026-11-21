#!/usr/bin/env bash
# tests/test_responder_thread_context.sh — the responder in a multi-person
# Slack thread (design/conversation_memory.md, parts 1+2, thread context).
#
# Usage: tests/test_responder_thread_context.sh
#
# Andy and Braden talk to the identity in one Slack thread. When Braden's
# message triggers a reply, the prompt must carry Andy's messages from that
# thread (as user turns, with the bridge header naming the speaker) alongside
# Braden's own history, and the metrics must say how many came from the thread
# alone. A DM trigger gets no thread context. Stubbed llm; no LLM calls.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID THINK_CONTEXT_TAIL THINK_MODEL MONOLITH_REPLY_MODEL 2>/dev/null

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
ANDY="slack-U0614H65RN3-C0BMVH6LM4K-1787508187.726149"
BRADEN="slack-U095QV3JKA6-C0BMVH6LM4K-1787508187.726149"
BRADEN_DM="slack-U095QV3JKA6-D0BN1QD7D2N"
ID="$WORK/ident"
TRAJ_ID="cafe0000-0000-0000-0000-0000000000f1"
mkdir -p "$ID/memories" "$ID/trajectories/$TRAJ_ID" "$ID/run"
printf 'name=%s\ncreated=test\nroot_trajectory=%s\n' "$ME" "$TRAJ_ID" > "$ID/info.txt"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"

mkdir -p "$WORK/stub"
printf '#!/usr/bin/env bash\ncat "$STUB_REPLY_FILE"\n' > "$WORK/stub/llm"; chmod +x "$WORK/stub/llm"
export STUB_REPLY_FILE="$WORK/reply"

ago() { date -u -v-"$1"S +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "$1 seconds ago" +%Y-%m-%dT%H:%M:%S.000Z; }
ahead() { date -u -v+"$1"S +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "$1 seconds" +%Y-%m-%dT%H:%M:%S.000Z; }
msg() {  # msg <id> <from> <to> <content> <secs-ago|+ahead>
    local ts; case "$5" in +*) ts=$(ahead "${5#+}") ;; *) ts=$(ago "$5") ;; esac
    printf '{"step_id":"%s","type":"message","from":"%s","to":"%s","content":"%s","ts":"%s","source":"chat"}\n' "$1" "$2" "$3" "$4" "$ts" >> "$TRAJ"
}
run_step() {
    printf '%s' "$1" | env PATH="$WORK/stub:$REPO/bin:$REPO/tools:$PATH" \
        IDENTITY_DIR="$ID" IDENTITY_NAME="$ME" MEM_DIR="$ID/memories" \
        TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID" HOME="$WORK/home" \
        SHELLM_MODEL=stub-model THINK_CONTEXT_TAIL=20 RESPONDER_PERSON_NOTES=0 \
        RESPONDER_LOG_PROMPT=1 "$STEP" >> "$WORK/step.log" 2>&1
}
obs_for() { jq -c --arg t "$1" 'select(.type=="observation" and .source=="responder" and (.trigger_step // "")==$t and (.decision // "")!="")' "$TRAJ" | tail -1; }
plog() { cat "$ID/run/logs/responder-prompts/"*"$1"* 2>/dev/null; }

: > "$TRAJ"
printf '{"step_id":"hdr","type":"trajectory","ts":"%s"}\n' "$(ago 99999)" >> "$TRAJ"
msg a1 "$ANDY"   "$ME"   "(Slack: Andy Konwinski in #headlong-bot) can you paste the tweet into the channel?" 600
msg r1 "$ME"     "$ANDY" "Sure, posting it now."                                                           590
msg b0 "$BRADEN" "$ME"   "(Slack: Braden in #headlong-bot) unrelated: how was the eval run?"             300000   # 3.5 days ago, another thread would be different ts; same thread here
msg b1 "$BRADEN" "$ME"   "(Slack: Braden in #headlong-bot) wait, which tweet?"                             +5

# --- 1. Braden's trigger sees Andy's thread messages -------------------------
printf 'The launch tweet Andy asked me to post.\n' > "$STUB_REPLY_FILE"
run_step "$(grep -F '"step_id":"b1"' "$TRAJ")"
obs=$(obs_for b1)
ctx=$(printf '%s' "$obs" | jq -r .context_msgs); thr=$(printf '%s' "$obs" | jq -r .thread_msgs)
if [[ "$ctx" == 3 && "$thr" == 2 ]]; then
    ok "context_msgs 3 (Braden's own b0 + Andy's a1 + our r1), thread_msgs 2"
else
    bad "context_msgs 3, thread_msgs 2" "got context_msgs=$ctx thread_msgs=$thr"
fi
if plog b1 | grep -q 'Andy Konwinski in #headlong-bot) can you paste the tweet' && plog b1 | grep -q '"role":"assistant","content":"Sure, posting it now."'; then
    ok "the prompt carries Andy's message as a user turn and our reply as an assistant turn"
else
    bad "the prompt carries Andy's message and our reply" "$(plog b1 | grep -o '"role":"[a-z]*","content":"[^"]\{0,50\}' | head -5 | tr '\n' ' ')"
fi
plog b1 | grep -q 'you are answering slack-U095QV3JKA6' && ok "the system prompt says who is being answered" || bad "the system prompt says who is being answered"
if plog b1 | jq -R 'fromjson? // empty' >/dev/null 2>&1; then :; fi
last_user=$(plog b1 | sed -n '/^# messages/,$p' | sed 1d | jq -r '.[-1].content' 2>/dev/null)
[[ "$last_user" == *"which tweet"* ]] && ok "the trigger is still the last turn" || bad "the trigger is still the last turn" "got '$last_user'"
printf '%s' "$obs" | jq -e '.context_steps | index("a1") and index("r1") and index("b0")' >/dev/null && ok "context_steps lists the thread steps" || bad "context_steps lists the thread steps"

# --- 2. a DM trigger from Braden gets his history but no thread ------------
msg d1 "$BRADEN_DM" "$ME" "(Slack: Braden DM) and the eval?" +10
printf 'Still running.\n' > "$STUB_REPLY_FILE"
run_step "$(grep -F '"step_id":"d1"' "$TRAJ")"
obs=$(obs_for d1)
ctx=$(printf '%s' "$obs" | jq -r .context_msgs); thr=$(printf '%s' "$obs" | jq -r .thread_msgs)
if [[ "$thr" == 0 && "$ctx" -ge 3 ]]; then
    ok "a DM gets Braden's cross-thread history (incl. our thread reply to him) and no thread context"
else
    bad "a DM gets history but no thread context" "context_msgs=$ctx thread_msgs=$thr"
fi
if ! plog d1 | grep -q 'can you paste the tweet'; then
    ok "Andy's thread message is not in Braden's DM prompt"
else
    bad "Andy's thread message is not in Braden's DM prompt"
fi

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
