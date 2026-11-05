#!/usr/bin/env bash
# tests/test_responder_notes_cut_marker.sh — the responder's notes-rewrite
# prompt renders each history row at 600 chars. The cut was silent: a
# message longer than 600 chars fed the notes model a half sentence, and
# the model is told to keep "ongoing threads and open commitments with
# dates", so a promise could read as made and then cut off mid word. The
# cut is now marked with the dropped count and a route, the same marker
# shape as the recap row cut, and the notes prompt tells the model a marked
# line is a partial message whose text continues in the raw log. Rows that
# fit render whole with no marker, and the reply path renders content whole
# (no 600 cap there).
#
# Usage: tests/test_responder_notes_cut_marker.sh
# Stubbed llm; no LLM calls.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID THINK_CONTEXT_TAIL 2>/dev/null

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
THEM="slack-U0614H65RN3-C0BMVH6LM4K-1787508187.726149"
ID="$WORK/ident"
TRAJ_ID="cafe0000-0000-0000-0000-0000000000f0"
mkdir -p "$ID/memories" "$ID/trajectories/$TRAJ_ID" "$ID/run"
printf 'name=%s\ncreated=test\nroot_trajectory=%s\n' "$ME" "$TRAJ_ID" > "$ID/info.txt"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"

# The stub answers the notes call (system prompt mentions "private notes")
# from one file and the reply call from another, and records both prompts.
mkdir -p "$WORK/stub"
cat > "$WORK/stub/llm" <<'STUB'
#!/usr/bin/env bash
sys=""; user=""; prev=""
for a in "$@"; do
    [[ "$prev" == "-s" ]] && sys="$a"
    [[ "$prev" == "-M" ]] && user="$a"
    prev="$a"
done
if [[ "$sys" == *"private notes"* ]]; then
    printf '%s\n' "$sys" > "$STUB_NOTES_SYS"
    printf '%s\n' "$user" > "$STUB_NOTES_USER"
    cat "$STUB_NOTES_FILE"
else
    printf '%s\n' "$sys" > "$STUB_REPLY_SYS"
    printf '%s\n' "$user" > "$STUB_REPLY_USER"
    cat "$STUB_FILE"
fi
STUB
chmod +x "$WORK/stub/llm"
export STUB_FILE="$WORK/reply" STUB_REPLY_SYS="$WORK/reply.sys" STUB_REPLY_USER="$WORK/reply.user"
export STUB_NOTES_FILE="$WORK/notes" STUB_NOTES_SYS="$WORK/notes.sys" STUB_NOTES_USER="$WORK/notes.user"

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

: > "$TRAJ"
printf '{"step_id":"hdr","type":"trajectory","ts":"%s"}\n' "$(now)" >> "$TRAJ"

LONG800=$(printf '%*s' 800 '' | tr ' ' 'A')   # exactly 800 As
LONG650=$(printf '%*s' 650 '' | tr ' ' 'A')   # exactly 650 As

# --- 1. a row over 600 chars carries the cut marker -----------------------
msg trig-1 "$THEM" "$ME" "$LONG800"
printf 'Hi Andy, will do.\n' > "$STUB_FILE"
printf 'stub notes body line\n' > "$STUB_NOTES_FILE"
: > "$STUB_NOTES_USER"; : > "$STUB_NOTES_SYS"; : > "$STUB_REPLY_USER"; : > "$STUB_REPLY_SYS"
run_step "$(grep -F '"step_id":"trig-1"' "$TRAJ")"

if grep -q ' (+200 more: full message in the raw log)' "$STUB_NOTES_USER"; then
    ok "an 800-char row carries (+200 more: full message in the raw log)"
else
    bad "an 800-char row carries the cut marker with the dropped count" "$(grep -oE 'them: A+[^(]*' "$STUB_NOTES_USER" | head -1 | cut -c1-100)"
fi
if grep -qE 'A{600} \(\+200 more' "$STUB_NOTES_USER"; then
    ok "the marked row keeps a 600-char prefix before the marker"
else
    bad "the marked row keeps a 600-char prefix before the marker" "$(grep -oE 'A{595,}' "$STUB_NOTES_USER" | awk '{print length($0)}')"
fi
if ! grep -qE 'A{601}' "$STUB_NOTES_USER"; then
    ok "the notes prompt shows at most 600 chars of the cut row"
else
    bad "the notes prompt shows at most 600 chars of the cut row" "prefix runs past 600"
fi

# --- 2. a barely-over row (650) also marks -------------------------------
msg trig-2 "$THEM" "$ME" "$LONG650"
printf 'Not yet.\n' > "$STUB_FILE"
printf 'stub notes body line\n' > "$STUB_NOTES_FILE"
run_step "$(grep -F '"step_id":"trig-2"' "$TRAJ")"
if grep -q ' (+50 more: full message in the raw log)' "$STUB_NOTES_USER"; then
    ok "a 650-char row marks (+50 more: ...)"
else
    bad "a 650-char row marks (+50 more: ...)" "$(grep -c 'more:' "$STUB_NOTES_USER")"
fi

# --- 3. a fitting row renders whole with no marker -----------------------
msg trig-3 "$THEM" "$ME" "short message that fits"
printf 'Sure.\n' > "$STUB_FILE"
printf 'stub notes body line\n' > "$STUB_NOTES_FILE"
run_step "$(grep -F '"step_id":"trig-3"' "$TRAJ")"
if ! grep -q 'short message that fits (+' "$STUB_NOTES_USER" && grep -q 'short message that fits' "$STUB_NOTES_USER"; then
    ok "a row that fits renders whole with no marker"
else
    bad "a row that fits renders whole with no marker" "fitting row altered or marked"
fi

# --- 4. the notes system prompt tells the model a marked line is partial --
if grep -q 'cut message' "$STUB_NOTES_SYS" && grep -q 'never quote its ending as the whole message' "$STUB_NOTES_SYS"; then
    ok "the notes prompt tells the model a marked line is a partial message"
else
    bad "the notes prompt tells the model a marked line is partial" "$(grep -c 'cut message' "$STUB_NOTES_SYS")"
fi

# --- 5. the reply path renders content whole, no 600 cap ------------------
if grep -qE 'A{800}' "$STUB_REPLY_USER"; then
    ok "the reply prompt carries all 800 chars of the long message"
else
    bad "the reply prompt carries the whole long message" "$(grep -oE 'A{590,}' "$STUB_REPLY_USER" | awk '{print length($0)}' | head -1)"
fi
if ! grep -q 'more: full message in the raw log' "$STUB_REPLY_USER"; then
    ok "the reply path takes no marker route"
else
    bad "the reply path takes no marker route" "marker leaked into the reply prompt"
fi
if grep -q 'facts and stated' "$STUB_NOTES_SYS" && grep -qi 'never turn one incident into a rule' "$STUB_NOTES_SYS"; then
    ok "the existing facts-only rules survive the prompt edit"
else
    bad "the existing facts-only rules survive the prompt edit"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "PASS notes-cut-marker ($pass checks)"
    exit 0
fi
echo "FAIL notes-cut-marker: $fail failures"
exit 1
