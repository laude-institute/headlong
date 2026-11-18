#!/usr/bin/env bash
# tests/test_responder_person_summary_marker.sh — the responder's person-notes
# writer bakes the card's stored summary at write time as
# "Notes on <person>: <first body line>" cut at 60 chars, silently, so every
# later mem list/search row for that card showed a summary ending mid word,
# baked into the store. The adjacent bound in the same writer, the 20-line
# cap on the notes body, dropped overflow the same way. Both caps stay (the
# first bounds the display row, the second is the backstop behind the
# prompt's 12-line rule); both drops are now marked with the store's own
# summary marker convention (bin/mem bake_summary): the dropped count plus a
# route where one exists. The summary's route is the card body, which holds
# the whole line; the body cap's dropped lines are kept nowhere, so its
# marker names the count and says so. Rows that fit render unchanged.
#
# Usage: tests/test_responder_person_summary_marker.sh
# Stubbed llm; no LLM calls.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID THINK_CONTEXT_TAIL 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
STEP="$REPO/thinkers/responder/step"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL jq not found"; exit 1; }

WORK=$(mktemp -d); trap 'cd /; rm -rf "$WORK"' EXIT

ME=testid
# A thread-shaped sender: the "Notes on <sender>: " prefix alone consumes
# 57 of the 60 summary chars, so this card cuts on almost any body line.
THEM="slack-U0614H65RN3-C0BMVH6LM4K-1787508187.726149"
# A short sender, so "the line fits" arms are reachable at all.
THEM_S="pwa-zed"
ID="$WORK/ident"
TRAJ_ID="cafe0000-0000-0000-0000-0000000000f0"
mkdir -p "$ID/memories" "$ID/trajectories/$TRAJ_ID" "$ID/run"
printf 'name=%s\ncreated=test\nroot_trajectory=%s\n' "$ME" "$TRAJ_ID" > "$ID/info.txt"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"

mkdir -p "$WORK/stub"
cat > "$WORK/stub/llm" <<'STUB'
#!/usr/bin/env bash
sys=""; prev=""
for a in "$@"; do [[ "$prev" == "-s" ]] && sys="$a"; prev="$a"; done
if [[ "$sys" == *"private notes"* ]]; then
    printf '%s\n' "$sys" > "$STUB_NOTES_SYS"
    cat "$STUB_NOTES_FILE"
else
    printf '%s\n' "$sys" > "$STUB_REPLY_SYS"
    cat "$STUB_REPLY_FILE"
fi
STUB
chmod +x "$WORK/stub/llm"
export STUB_REPLY_FILE="$WORK/reply" STUB_NOTES_FILE="$WORK/notes" STUB_NOTES_SYS="$WORK/notes.sys" STUB_REPLY_SYS="$WORK/reply.sys"

run_step() {  # run_step <trigger json> [extra env...]
    local trig="$1"; shift
    printf '%s' "$trig" | env \
        PATH="$WORK/stub:$REPO/bin:$REPO/tools:$PATH" \
        IDENTITY_DIR="$ID" IDENTITY_NAME="$ME" MEM_DIR="$ID/memories" \
        TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID" HOME="$WORK/home" \
        SHELLM_MODEL=stub-model THINK_CONTEXT_TAIL=20 \
        RESPONDER_PERSON_NOTES_SYNC=1 "$@" \
        "$STEP" >> "$WORK/step.log" 2>&1
}
now() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }
msg() { printf '{"step_id":"%s","type":"message","from":"%s","to":"%s","content":"%s","ts":"%s","source":"chat"}\n' "$1" "$2" "$3" "$4" "$(now)" >> "$TRAJ"; }

card_of() {  # card_of <full sender> — the person card file, by its summary prefix
    awk -v p="summary: Notes on $1: " 'index($0, p)==1 {print FILENAME}' "$ID/memories"/*.md 2>/dev/null | head -1
}
summary_of() { sed -n 's/^summary: //p' "$(card_of "$1")" | head -1; }
body_first() { awk 'c==2 && NF {print; exit} /^---$/ {c++}' "$(card_of "$1")"; }
body_lines() { awk '/^---$/ {c++; next} c>=2 && NF' "$(card_of "$1")" | wc -l | tr -d ' '; }
# expected summary, derived from first principles: 60 bytes, whole chars only
exp_summary() {  # exp_summary <sender> <first body line>
    local line="Notes on $1: $2" clip dropped
    clip=$(printf '%s' "$line" | head -c 60 | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)
    dropped=$(( ${#line} - ${#clip} ))
    if (( dropped > 0 )); then printf '%s +%d chars (route: full line in the memory body)' "$clip" "$dropped"
    else printf '%s' "$clip"; fi
}

: > "$TRAJ"
printf '{"step_id":"hdr","type":"trajectory","ts":"%s"}\n' "$(now)" >> "$TRAJ"

# --- 1. a long first line bakes a marked summary (create path) -------------
L1="Andy runs the lab and reaches testid on Slack threads and DMs and prefers short plain replies without bullet lists or headers in the messages he sends"
msg trig-1 "$THEM" "$ME" "hi, notes please"
printf 'Hi.\n' > "$STUB_REPLY_FILE"
printf '%s\nsecond\n' "$L1" > "$STUB_NOTES_FILE"
run_step "$(grep -F '"step_id":"trig-1"' "$TRAJ")"
WANT1=$(exp_summary "$THEM" "$L1")
S1=$(summary_of "$THEM")
[[ -n "$(card_of "$THEM")" ]] && ok "the person card exists" || bad "the person card exists" "$(tail -3 "$WORK/step.log")"
if [[ "$S1" == "$WANT1" ]]; then
  ok "a long summary is clipped at 60 and marked with the dropped count and a route"
else
  bad "a long summary is clipped and marked" "summary: $S1"
fi

# --- 2. the card body holds the whole first line, uncut ---------------------
[[ "$(body_first "$THEM")" == "$L1" ]] && ok "the body holds the whole first line, uncut" \
  || bad "the body holds the whole first line" "$(body_first "$THEM")"

# --- 3. a fitting line renders whole with no marker (short sender) ----------
L2="Prefers short replies"
msg trig-3 "$THEM_S" "$ME" "ping"
printf 'pong\n' > "$STUB_REPLY_FILE"
printf '%s\nsecond\n' "$L2" > "$STUB_NOTES_FILE"
run_step "$(grep -F '"step_id":"trig-3"' "$TRAJ")"
S3=$(summary_of "$THEM_S")
if [[ "$S3" == "Notes on $THEM_S: $L2" ]]; then
  ok "a summary that fits renders whole with no marker"
else
  bad "a summary that fits renders whole with no marker" "summary: $S3"
fi

# --- 4. the exact 60-char boundary carries no marker -----------------------
P="Notes on $THEM_S: "
L3=""
for ((k=0; k<60-${#P}; k++)); do L3+="x"; done
msg trig-4 "$THEM_S" "$ME" "boundary"
printf 'ok.\n' > "$STUB_REPLY_FILE"
printf '%s\nsecond\n' "$L3" > "$STUB_NOTES_FILE"
run_step "$(grep -F '"step_id":"trig-4"' "$TRAJ")"
S4=$(summary_of "$THEM_S")
[[ $(( ${#P} + ${#L3} )) -eq 60 ]] || { echo "FAIL boundary construction: $(( ${#P} + ${#L3} ))"; exit 1; }
if [[ "$S4" == "$P$L3" ]]; then
  ok "the exact 60-char boundary renders whole with no marker"
else
  bad "the exact 60-char boundary carries no marker" "summary: $S4"
fi

# --- 5. a multibyte line clips on a character boundary, marked -------------
L4="Audel — peer persona — runs on shellm — stays on the tracks — asks before judging — replies in threads — keeps promises — plain words"
msg trig-5 "$THEM" "$ME" "utf8 probe"
printf 'fine.\n' > "$STUB_REPLY_FILE"
printf '%s\nsecond\n' "$L4" > "$STUB_NOTES_FILE"
run_step "$(grep -F '"step_id":"trig-5"' "$TRAJ")"
WANT5=$(exp_summary "$THEM" "$L4")
S5=$(summary_of "$THEM")
if [[ "$S5" == "$WANT5" ]]; then
  ok "a multibyte summary marks the drop with the same route"
else
  bad "a multibyte summary marks the drop" "summary: $S5"
fi
clip5="${S5%% +*}"
if printf '%s' "$clip5" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
  ok "the clip ends on a whole character, never mid character"
else
  bad "the clip ends on a whole character" "$clip5"
fi
[[ "$(body_first "$THEM")" == "$L4" ]] && ok "the multibyte body line is stored whole" \
  || bad "the multibyte body line is stored whole" "$(body_first "$THEM")"

# --- 6. the rewrite path marks a long line identically ----------------------
msg trig-6 "$THEM" "$ME" "one more"
printf 'yes.\n' > "$STUB_REPLY_FILE"
printf '%s\nsecond\n' "$L1" > "$STUB_NOTES_FILE"
run_step "$(grep -F '"step_id":"trig-6"' "$TRAJ")"
S6=$(summary_of "$THEM")
if [[ "$S6" == "$WANT1" ]]; then
  ok "the rewrite path marks a long line identically"
else
  bad "the rewrite path marks a long line identically" "summary: $S6"
fi
[[ "$(card_of "$THEM" | wc -l | tr -d ' ')" == 1 ]] && ok "still one card for the sender, no duplicates" \
  || bad "still one card for the sender, no duplicates"

# --- 7. the 20-line body cap marks the lines it drops -----------------------
{
  for i in $(seq 1 25); do printf 'l%02d fact line\n' "$i"; done
} > "$STUB_NOTES_FILE"
msg trig-7 "$THEM_S" "$ME" "long notes"
printf 'ok, noted.\n' > "$STUB_REPLY_FILE"
run_step "$(grep -F '"step_id":"trig-7"' "$TRAJ")"
F_S=$(card_of "$THEM_S")
LAST7=$(awk '/^---$/ {c++; next} c>=2 && NF' "$F_S" | tail -1)
if [[ "$LAST7" == "(+5 more lines: dropped by the 20-line writer cap, not kept anywhere)" ]]; then
  ok "the body cap keeps 20 lines and marks 5 dropped"
else
  bad "the body cap marks the dropped count" "$LAST7"
fi
if [[ "$(body_lines "$THEM_S")" == 21 ]] && ! grep -q 'l21 fact' "$F_S"; then
  ok "the body holds the 20 kept lines plus the marker, overflow gone"
else
  bad "the body holds 20 lines plus the marker" "$(body_lines "$THEM_S") lines"
fi
if [[ "$(summary_of "$THEM_S")" == "Notes on $THEM_S: l01 fact line" ]]; then
  ok "the summary is baked from the first body line, unaffected by the cap marker"
else
  bad "the summary is baked from the first body line" "summary: $(summary_of "$THEM_S")"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "PASS person-summary-marker ($pass checks)"
  exit 0
fi
echo "FAIL person-summary-marker: $fail failures"
exit 1
