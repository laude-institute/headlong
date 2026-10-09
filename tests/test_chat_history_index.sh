#!/usr/bin/env bash
# tests/test_chat_history_index.sh — `chat history --with`, the derived message
# index behind it, and person keys (design/conversation_memory.md, parts 1+2).
#
# Usage: tests/test_chat_history_index.sh
#
# Builds a throwaway trajectory by hand, then checks: the index is created next
# to the trajectory and only holds message steps; --with groups one human's
# Slack thread names and DM name under one person key; --since and -n bound the
# result; the index picks up lines appended later without a rebuild; a partial
# last line (a write in progress) is not consumed until it is complete; a
# replaced trajectory (different header) triggers a rebuild; and `type: person`
# memories merge aliases across channels. No LLM calls, no docker.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

command -v jq >/dev/null 2>&1 || { echo "FAIL jq not found"; exit 1; }

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT

ME=ada
ID="$WORK/ident"
TRAJ_ID="cafe0000-0000-0000-0000-0000000000cd"
mkdir -p "$ID/memories" "$ID/trajectories/$TRAJ_ID"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"
IDX="$ID/trajectories/$TRAJ_ID/messages.jsonl"
export IDENTITY_NAME="$ME" TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID" MEM_DIR="$ID/memories"

ago() {  # ISO timestamp N seconds ago
    date -u -v-"$1"S +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
        || date -u -d "$1 seconds ago" +%Y-%m-%dT%H:%M:%S.000Z
}
header() { printf '{"step_id":"%s","type":"trajectory","ts":"%s"}\n' "$1" "$(ago 999999)" >> "$TRAJ"; }
msg() {  # msg <id> <from> <to> <content> <secs-ago>
    printf '{"step_id":"%s","type":"message","from":"%s","to":"%s","content":"%s","ts":"%s","source":"chat"}\n' \
        "$1" "$2" "$3" "$4" "$(ago "$5")" >> "$TRAJ"
}
noise() { printf '{"step_id":"%s","type":"reasoning","content":"...\\"type\\":\\"message\\" mentioned in prose","ts":"%s"}\n' "$1" "$(ago 5)" >> "$TRAJ"; }

ANDY_T1="slack-U0614H65RN3-C0BMVH6LM4K-1787508187.726149"
ANDY_T2="slack-U0614H65RN3-C0BMVH6LM4K-1787419141.482799"
ANDY_DM="slack-U0614H65RN3-D0BNW58GP5W"
BRADEN="slack-U095QV3JKA6-C0BMVH6LM4K-1787508187.726149"

# --- person keys -------------------------------------------------------------
[[ "$(chat person-key "$ANDY_T1")" == "slack:U0614H65RN3" ]] && ok "slack thread name -> slack:user" || bad "slack thread name -> slack:user" "got $(chat person-key "$ANDY_T1")"
[[ "$(chat person-key "$ANDY_DM")" == "slack:U0614H65RN3" ]] && ok "slack DM name -> same key" || bad "slack DM name -> same key"
[[ "$(chat person-key telegram-8525624593-8525624593)" == "telegram:8525624593" ]] && ok "telegram name -> telegram:id" || bad "telegram name -> telegram:id"
[[ "$(chat person-key pwa-andy)" == "pwa:andy" ]] && ok "pwa name -> pwa:name" || bad "pwa name -> pwa:name"
[[ "$(chat person-key Andy)" == "Andy" ]] && ok "bare name is its own key" || bad "bare name is its own key"

# --- a conversation spread over threads, a DM, and 8 days --------------------
: > "$TRAJ"
header hdr-1
msg a1 "$ANDY_T1" "$ME"   "how is the bridge work going"   $((8*86400))   # older than 7d
msg a2 "$ME"      "$ANDY_T1" "half done"                    $((8*86400-60))
noise n1
msg a3 "$ANDY_T2" "$ME"   "that svg is not rendering"       7200
msg a4 "$ME"      "$ANDY_T2" "slack ate it"                 7100
msg b1 "$BRADEN"  "$ME"   "middle name of washington?"      3600
msg b2 "$ME"      "$BRADEN" "he had none"                   3500
msg a5 "$ANDY_DM" "$ME"   "sure!"                           60
noise n2

out=$(chat history --with "$ANDY_T1" --json)
n=$(printf '%s' "$out" | jq 'length')
[[ "$n" == 5 ]] && ok "--with groups two threads and the DM under one person (5 msgs)" || bad "--with groups two threads and the DM under one person" "got $n: $out"
if printf '%s' "$out" | jq -e 'map(.step_id) == ["a1","a2","a3","a4","a5"]' >/dev/null; then
    ok "history is in time order, newest last"
else
    bad "history is in time order, newest last" "$(printf '%s' "$out" | jq -c 'map(.step_id)')"
fi
if printf '%s' "$out" | jq -e 'map(.step_id) | index("b1") == null' >/dev/null; then
    ok "another person in the same thread is excluded"
else
    bad "another person in the same thread is excluded"
fi
n=$(chat history --with "$ANDY_DM" --since 7d --json | jq 'length')
[[ "$n" == 3 ]] && ok "--since 7d drops the 8 day old exchange" || bad "--since 7d drops the 8 day old exchange" "got $n"
n=$(chat history --with "slack:U0614H65RN3" -n 2 --json | jq 'length')
[[ "$n" == 2 ]] && ok "-n caps the result; a person key works as --with" || bad "-n caps the result; a person key works as --with" "got $n"
last=$(chat history --with "$ANDY_T1" -n 1 --json | jq -r '.[0].step_id')
[[ "$last" == a5 ]] && ok "-n keeps the newest" || bad "-n keeps the newest" "got $last"
if chat history --with "$ANDY_T1" | grep -q 'sure!'; then
    ok "text output renders the messages"
else
    bad "text output renders the messages"
fi

# --- threads: everyone in one Slack thread ------------------------------------
# a3/a4 are Andy in thread T2; b1/b2 are Braden in thread T1, which is the same
# thread as Andy's a1/a2 (both use thread ts 1787508187.726149).
[[ "$(chat thread-key "$ANDY_T1")" == "slack-thread:C0BMVH6LM4K-1787508187.726149" ]] && ok "slack thread name -> thread key" || bad "slack thread name -> thread key" "got $(chat thread-key "$ANDY_T1")"
[[ -z "$(chat thread-key "$ANDY_DM")" && -z "$(chat thread-key pwa-andy)" ]] && ok "DMs and the phone chat have no thread key" || bad "DMs and the phone chat have no thread key"
out=$(chat history --thread "$BRADEN" --json)
if printf '%s' "$out" | jq -e 'map(.step_id) == ["a1","a2","b1","b2"]' >/dev/null; then
    ok "--thread returns everyone's messages in that thread, in order"
else
    bad "--thread returns everyone's messages in that thread" "$(printf '%s' "$out" | jq -c 'map(.step_id)')"
fi
n=$(chat history --thread "$BRADEN" --since 1d --json | jq 'length')
[[ "$n" == 2 ]] && ok "--thread --since bounds the thread window" || bad "--thread --since bounds the thread window" "got $n"
out=$(chat history --with "$BRADEN" --thread "$BRADEN" --json)
if printf '%s' "$out" | jq -e 'map(.step_id) == ["a1","a2","b1","b2"]' >/dev/null; then
    ok "--with plus --thread is the de-duplicated union"
else
    bad "--with plus --thread is the de-duplicated union" "$(printf '%s' "$out" | jq -c 'map(.step_id)')"
fi
n=$(chat history --thread "$ANDY_DM" --json | jq 'length')
[[ "$n" == 0 ]] && ok "--thread on a DM name returns nothing" || bad "--thread on a DM name returns nothing" "got $n"
n=$(chat history --thread "slack-thread:C0BMVH6LM4K-1787508187.726149" -n 1 --json | jq 'length')
[[ "$n" == 1 ]] && ok "a thread key works as --thread" || bad "a thread key works as --thread" "got $n"

# --- the index itself -------------------------------------------------------
[[ -f "$IDX" ]] && ok "index created next to the trajectory" || bad "index created next to the trajectory"
if [[ "$(jq -r .step_id "$IDX" | grep -c '^n')" == 0 ]] && [[ "$(wc -l < "$IDX" | tr -d ' ')" == 7 ]]; then
    ok "index holds only the 7 message steps (noise lines mentioning message are skipped)"
else
    bad "index holds only the 7 message steps" "$(wc -l < "$IDX") lines"
fi
read -r off hdr _ < "$IDX.offset"   # offset, header, then inode and size (2026-09-15)
[[ "$off" == "$(wc -c < "$TRAJ" | tr -d ' ')" && "$hdr" == hdr-1 ]] && ok "offset file records the consumed bytes and the header" || bad "offset file records the consumed bytes and the header" "got '$off $hdr'"

# incremental: append, no rebuild
msg a6 "$ANDY_DM" "$ME" "still there?" 10
before_lines=$(wc -l < "$IDX" | tr -d ' ')
n=$(chat history --with "$ANDY_T1" --json | jq 'length')
[[ "$n" == 6 && "$(wc -l < "$IDX" | tr -d ' ')" == $((before_lines+1)) ]] && ok "a later append is picked up incrementally" || bad "a later append is picked up incrementally" "n=$n lines=$(wc -l < "$IDX")"

# partial last line: not consumed, offset not advanced past it
printf '{"step_id":"a7","type":"message","from":"%s","to":"%s","content":"half writ' "$ANDY_DM" "$ME" >> "$TRAJ"
n=$(chat history --with "$ANDY_T1" --json | jq 'length')
read -r off hdr _ < "$IDX.offset"   # offset, header, then inode and size (2026-09-15)
full=$(wc -c < "$TRAJ" | tr -d ' ')
if [[ "$n" == 6 && "$off" -lt "$full" ]]; then
    ok "a partial last line is left for the next call"
else
    bad "a partial last line is left for the next call" "n=$n off=$off size=$full"
fi
printf 'ten","ts":"%s","source":"chat"}\n' "$(ago 5)" >> "$TRAJ"
n=$(chat history --with "$ANDY_T1" --json | jq 'length')
[[ "$n" == 7 ]] && ok "the completed line is picked up next time" || bad "the completed line is picked up next time" "got $n"

# rebuild when the trajectory is replaced (different header)
: > "$TRAJ"
header hdr-2
msg z1 pwa-andy "$ME" "hello from the phone" 30
n=$(chat history --with pwa-andy --json | jq 'length')
read -r off hdr _ < "$IDX.offset"   # offset, header, then inode and size (2026-09-15)
[[ "$n" == 1 && "$hdr" == hdr-2 && "$(wc -l < "$IDX" | tr -d ' ')" == 1 ]] && ok "a replaced trajectory rebuilds the index" || bad "a replaced trajectory rebuilds the index" "n=$n hdr=$hdr lines=$(wc -l < "$IDX")"

# --- aliases via a person memory ---------------------------------------------
msg z2 "$ANDY_DM" "$ME" "and from slack" 20
cat > "$ID/memories/2026-09-02-00-00-00_abcd1234_andy.md" <<'MEM'
---
id: abcd1234
type: person
person_key: slack:U0614H65RN3
aliases: [pwa:andy, Andy]
summary: Andy, co-founder
---
Andy prefers short replies.
MEM
n=$(chat history --with pwa-andy --json | jq 'length')
[[ "$n" == 2 ]] && ok "aliases in a person memory merge channels (asked via pwa name)" || bad "aliases merge channels (asked via pwa name)" "got $n"
n=$(chat history --with "$ANDY_T2" --json | jq 'length')
[[ "$n" == 2 ]] && ok "aliases merge channels (asked via slack name)" || bad "aliases merge channels (asked via slack name)" "got $n"
n=$(chat history --with Braden --json | jq 'length')
[[ "$n" == 0 ]] && ok "an unrelated name gets nothing" || bad "an unrelated name gets nothing" "got $n"

# --- person files with empty aliases -------------------------------------------
# The responder writes every person file on first contact with `aliases: []`
# and a timestamped name that sorts last in MEM_DIR. A false `[[ -n ]] &&`
# guard used to be the loop's last status in _person_aliases, and bin/chat
# runs `set -e -o pipefail`, so the empty aliases made `chat history --with`
# exit 1 with no output for that person.
msg z3 "$BRADEN" "$ME" "still here" 15
MEM2="$WORK/memories-lone"
mkdir -p "$MEM2"
cat > "$MEM2/2026-09-30-13-00-00_bbbb2222_braden.md" <<'MEM'
---
id: bbbb2222
type: person
person_key: slack:U095QV3JKA6
aliases: []
summary: Braden, first contact
---
First contact note.
MEM
rc=0
out=$(MEM_DIR="$MEM2" chat history --with "$BRADEN" --json) || rc=$?
n=$(printf '%s' "$out" | jq 'length')
[[ "$rc" == 0 && "$n" == 1 ]] && ok "a lone person file with empty aliases does not break history" || bad "a lone person file with empty aliases does not break history" "rc=$rc n=$n"
cat > "$ID/memories/2026-09-30-13-30-00_cccc3333_andy-empty.md" <<'MEM'
---
id: cccc3333
type: person
person_key: slack:U0614H65RN3
aliases: []
summary: Andy, before any alias was learned
---
First contact note.
MEM
rc=0
out=$(chat history --with "$ANDY_T2" --json) || rc=$?
n=$(printf '%s' "$out" | jq 'length')
[[ "$rc" == 0 && "$n" == 2 ]] && ok "an empty-alias person file sorting last does not break history" || bad "an empty-alias person file sorting last does not break history" "rc=$rc n=$n"

# --- source links ------------------------------------------------------------
SOURCE_URL="https://laudesters.slack.com/archives/D0BNW58GP5W/p1788451200123456"
chat send --from "$ANDY_DM" --to "$ME" --source-url "$SOURCE_URL" "linked message" 2>/dev/null
if tail -n 1 "$TRAJ" | jq -e --arg url "$SOURCE_URL" \
    '.type == "message" and .content == "linked message" and .source_url == $url' >/dev/null; then
    ok "chat send keeps an optional source URL on the message step"
else
    bad "chat send keeps an optional source URL on the message step"
fi

# Message content travels through stdin, not an argv string. Linux rejects a
# single argument above 128 KiB, so these checks guard both write paths.
LARGE_MESSAGE="$WORK/large-message.txt"
dd if=/dev/zero bs=1024 count=150 2>/dev/null | tr '\0' x > "$LARGE_MESSAGE"
large_bytes=$(wc -c < "$LARGE_MESSAGE" | tr -d ' ')
chat send --from "$ANDY_DM" --to "$ME" < "$LARGE_MESSAGE" 2>/dev/null
got_bytes=$(tail -n 1 "$TRAJ" | jq -r '.content | length')
if [[ "$got_bytes" == "$large_bytes" ]]; then
    ok "chat send preserves a message larger than Linux's argument limit"
else
    bad "chat send preserves a message larger than Linux's argument limit" "got $got_bytes bytes"
fi
chat reply --reply-to large-test --follow-up "$ANDY_DM" < "$LARGE_MESSAGE" 2>/dev/null
got_bytes=$(tail -n 1 "$TRAJ" | jq -r '.content | length')
if [[ "$got_bytes" == "$large_bytes" ]]; then
    ok "chat reply preserves a message larger than Linux's argument limit"
else
    bad "chat reply preserves a message larger than Linux's argument limit" "got $got_bytes bytes"
fi

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
