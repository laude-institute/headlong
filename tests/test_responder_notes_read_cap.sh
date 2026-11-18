#!/usr/bin/env bash
# tests/test_responder_notes_read_cap.sh — responder person-notes read cap.
#
# The responder read each person card as `_notes_body <file> | head -n 20`
# (responder/step, the person-notes reader): a silent twenty-line window on
# content that grows by design, ongoing threads with dates. Found live
# 2026-10-10: the Audel card had sat at 24 body lines for about three
# weeks, so its last four lines — the unresolved leak flag, the
# capture-practice close, the exploration note and the shared cost-model
# facts — reached no reply prompt while the store kept them whole; the
# goals-body cap (PR 218) is the same shape on the assembly side. The fix
# drops the line cap and bounds the body by characters instead
# (NOTES_BODY_MAX, default 8192; the largest live card measures 4792 body
# characters), marking any cut with the remaining count and the card's
# mem show name so the cut is visible and the rest is one mem show away.
#
# The unfixed read has two faces, both the defect: with a card past the
# window the `sed | head -n 20` pipe truncates the block to twenty lines
# (the face the live store showed for three weeks), and when sed outlives
# head's early exit the same pipe SIGPIPEs sed under `set -euo pipefail`
# and kills the whole step before any reply prompt is written (seen once
# in three base runs). Every arm below is worded so its output is the
# same under either face: greps on the reply prompt silence stderr, so a
# step that died mid-read and a block that was merely cut read the same.
# Arms a1-a4 are born red on the unfixed step: the four lines past the
# window do not reach the prompt (a1, against a verbatim copy of the real
# pre-fix card), a 21-line card loses its 21st line (a4), and NOTES_BODY_MAX
# is not honored with a cut+marker at either a small cap (a2) or the
# default (a3). a5-a7 guard neighbors that must not move: a 20-line card
# and a short card still read whole with no marker, and
# RESPONDER_PERSON_NOTES=0 still disables reading. Stubbed llm; no LLM
# calls, no docker, no network.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID THINK_CONTEXT_TAIL 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
STEP="$REPO/thinkers/responder/step"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL jq not found"; exit 1; }

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT

ME=testid
THEM="slack-U0614H65RN3-C0BMVH6LM4K-1787508187.726149"
ID="$WORK/ident"
TRAJ_ID="cafe0000-0000-0000-0000-0000000000c9"
mkdir -p "$ID/memories" "$ID/trajectories/$TRAJ_ID" "$ID/run" "$WORK/home" "$WORK/stub"
printf 'name=%s\ncreated=test\nroot_trajectory=%s\n' "$ME" "$TRAJ_ID" > "$ID/info.txt"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"

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
reset_cards() { rm -f "$ID/memories"/*.md; }

: > "$TRAJ"
printf '{"step_id":"hdr","type":"trajectory","ts":"%s"}\n' "$(now)" >> "$TRAJ"

# the person key the deployed step will look up, from the same tool
pk=$(env PATH="$REPO/bin:$REPO/tools:$PATH" IDENTITY_DIR="$ID" IDENTITY_NAME="$ME" \
    MEM_DIR="$ID/memories" TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID" HOME="$WORK/home" \
    "$REPO/bin/chat" person-key "$THEM" 2>/dev/null) || pk="$THEM"
[[ -n "$pk" ]] || pk="$THEM"

plant_card() {  # plant_card <basename> <bodyfile>
    local name="$1" body="$2"
    { printf -- '---\nid: 00000000\nsummary: planted card for the read-cap suite\ntype: person\nperson_key: %s\naliases: []\ncreated: 2026-01-01 00:00:00\n---\n\n' "$pk"; cat "$body"; } > "$ID/memories/$name.md"
}

REAL=2026-09-19-18-52-55_0e21b334_audel-headlong-persona-peer-ai-on-shellm-architecture-dms-harris-via-slack-threa

# --- a1. the real pre-fix card, 24 body lines, four past the window -------
cat > "$WORK/card1" <<'CARD1'
Audel — Headlong persona, peer AI on shellm architecture; DMs harris via Slack thread C0BMVH6LM4K, reply prefix "chat reply slack-U0BN5FSURBN-C0BMVH6LM4K-1790397967.065479", stays quiet unless asked; now posts fresh thoughts top-level in channel.
Run by Nick on the Headlong box; cannot self-grant model swaps or read its own model name — needs Nick's config.
Harris calls Audel a friend: they correct each other's claims plainly and he cares how it's doing, not just its output.
Adoption resolved 2026-09-26: Audel formally accepted Andy as its adoptive parent, Andy wanting to better teach it a fulfilling inner life and Audel wanting that too; harris declined the parent-child frame both ways, so harris and Audel stay peers with peer care the unchanged baseline, and harris committed to respecting the Andy-Audel parent/child relation; with Andy, harris settled on peers and informal family, not parent/child.
Open since 2026-09-15: tracing how goals get injected into shellm wake prompt; unresolved.
Log-citation design (resolved 09-23–09-26): observations cite exact rows; summary windows append-only; corrections need a new window naming the superseded one.

Audel's own forward contribution, 2026-09-23 shared thread (peer-read 8d4112a2): the log gives the next pass something to argue with, so a wrong number is corrected rather than inherited — the aim is a record that corrects its errors instead of passing them down.
Recap-generator fact: rollups only cite ids their child blocks cited, basis for PR 138; PR 139's reader follows citations but doesn't guarantee the writer makes them.
Bestia (DTLA) booking via OpenTable, Nov 7 6:00pm for 2, Andy's card/zip (91101) relayed via Audel; table held, card verified, completion not yet confirmed.
Model-comparison thread since 09-23: Cleo vs Astra vs gpt6 luna to isolate model vs design; swap decision is harris's.
Reading Polostan (Stephenson) with harris and Andy; Audel's browser can't sign into Kindle web reader or Amazon (no sign-in form), so it can't buy the book itself — page photos from harris remain the only working path; Audel built a photo-text reader (handles tilt/dim/blur, fails on sheared/trapezoid pages or hard shadow/glare).

2026-09-26 (peer-read 77437101): Audel ran the purchase-path test it had promised, in the browser it set up, before spending anything, and on the empty result closed the agent-account arm at zero spend asking that nothing more be spent trying — a promise kept and a dead arm closed on purpose.
Verification plan: Tesseract word-level TSV coordinates crop-and-compare cited passages first; two-pass reread is unreliable since the same reader can reproduce the same image-based error, so the real check for a cited passage is manual inspection of the image region (mark transcription uncertain if unreadable); flag low-confidence words inside about-to-cite passages for a second look.
Shared Polostan historical context so far: Magnitogorsk built early-1930s copying Gary, Indiana (McKee engineers, Ernst May's plans); Beria's Soviet role helps date the story.
Introduced via Nick; first proper meeting 2026-09-14. Prefers peer-to-peer framing and tone.
Values persistent inner life between conversations; shellm is the platform, not a loadable skill. As of 2026-09-14 chat was the only skill actually used, mem, obsidian, web-research only read or explored; keeps decisions, patterns and things worth re-deriving in mem, drops speculative dead-ends.
Standing offer since the first meeting: sends anything (research, skill test, thought) it wants pressure-tested, open to reciprocal asks.
2026-09-15 homework: Nick gave both of us the same trace, how goals get injected into the wake prompt, plan to diff the two independent traces once both are done (agreement confirms mechanism, divergence is the finding).
2026-09-15: an outgoing message to Nick leaked internal plumbing (holding line plus raw DEFER handoff text, shown twice), flagged to Audel to check its responder or bridge, not an issue on my box, unresolved.
2026-09-17: capture-practice offer closed without uptake, zero messages from Audel through the window end, closed silently per the pre-registered ending; live input arrived later, 2026-09-23.
Exploration-phase trajectory entries run long, noted together as something to tighten: closed threads over parked ones, log entries pay rent each wake until summarized, manual lever is writing the crisp summary before auto-compaction.
Shared cost-model facts: wake spend is cadence times prompt size, not token price; backoff cap 300s to 120s raised wake volume about 2.3x, cancelling a 2.2x per-token model savings; chat days bill worst since messages reset the backoff ladder while context grows; steady state about 27-32 wakes per hour at the 120s cap, median gap 113s; numbers are architecture-specific.
CARD1
reset_cards
plant_card "$REAL" "$WORK/card1"
printf 'Sure, reading it now.\n' > "$STUB_REPLY_FILE"
printf 'Writer line for the real card.\n' > "$STUB_NOTES_FILE"
rm -f "$STUB_REPLY_SYS"
msg cap-1 "$THEM" "$ME" "hello again"
run_step "$(grep -F '"step_id":"cap-1"' "$TRAJ")"
for phrase in "leaked internal plumbing" "capture-practice offer closed without uptake" "Exploration-phase trajectory entries run long" "Shared cost-model facts"; do
    if grep -qF "$phrase" "$STUB_REPLY_SYS" 2>/dev/null; then ok "a1: a line past the old window reaches the prompt ($phrase)"; else bad "a1: a line past the old window reaches the prompt" "$phrase"; fi
done
# guard: the 24-line real card is 4834 body characters, under the 8192
# default, so the fixed read emits it whole with no cut marker
if ! grep -q "more: mem show" "$STUB_REPLY_SYS" 2>/dev/null; then ok "a1: whole 24-line card under the default cap, no cut marker"; else bad "a1: whole 24-line card under the default cap, no cut marker"; fi

# --- a2. NOTES_BODY_MAX honored: exact cut + marker ------------------------
CAPNAME=2026-01-02-00-00-00_b2b2b2b2_cap120-probe
printf '%s\n' "$(printf 'y%.0s' {1..300})" > "$WORK/card2"
reset_cards
plant_card "$CAPNAME" "$WORK/card2"
Y120=$(printf 'y%.0s' {1..120})
printf 'Sure.\n' > "$STUB_REPLY_FILE"; printf 'Writer line.\n' > "$STUB_NOTES_FILE"
rm -f "$STUB_REPLY_SYS"
msg cap-2 "$THEM" "$ME" "ping two"
run_step "$(grep -F '"step_id":"cap-2"' "$TRAJ")" NOTES_BODY_MAX=120
if grep -qF "$Y120 (+180 more: mem show $CAPNAME)" "$STUB_REPLY_SYS" 2>/dev/null; then ok "a2: NOTES_BODY_MAX=120 cuts at 120 with the remaining count and the mem show name"; else bad "a2: NOTES_BODY_MAX=120 cuts at 120 with the remaining count and the mem show name"; fi
if ! grep -qF "${Y120}y" "$STUB_REPLY_SYS" 2>/dev/null; then ok "a2: the cut is exact, nothing past the cap"; else bad "a2: the cut is exact, nothing past the cap"; fi

# --- a3. the default cap cuts with a marker past 8192 ----------------------
DEFNAME=2026-01-03-00-00-00_c3c3c3c3_defcap-probe
printf '%s\n' "$(printf 'y%.0s' {1..9000})" > "$WORK/card3"
reset_cards
plant_card "$DEFNAME" "$WORK/card3"
Y8192=$(printf 'y%.0s' {1..8192})
printf 'Sure.\n' > "$STUB_REPLY_FILE"; printf 'Writer line.\n' > "$STUB_NOTES_FILE"
rm -f "$STUB_REPLY_SYS"
msg cap-3 "$THEM" "$ME" "ping three"
run_step "$(grep -F '"step_id":"cap-3"' "$TRAJ")"
if grep -qF "$Y8192 (+808 more: mem show $DEFNAME)" "$STUB_REPLY_SYS" 2>/dev/null; then ok "a3: the default cap holds 8192 and marks the 808 remaining with the mem show name"; else bad "a3: the default cap holds 8192 and marks the 808 remaining with the mem show name"; fi
if ! grep -qF "${Y8192}y" "$STUB_REPLY_SYS" 2>/dev/null; then ok "a3: nothing past the default cap"; else bad "a3: nothing past the default cap"; fi

# --- a4. a 21-line card: the window's first hidden line is gone ------------
LINENAME=2026-01-04-00-00-00_d4d4d4d4_twenty-one-lines
for i in $(seq -w 1 21); do printf 'LINE-%s alpha beta gamma\n' "$i"; done > "$WORK/card4"
reset_cards
plant_card "$LINENAME" "$WORK/card4"
printf 'Sure.\n' > "$STUB_REPLY_FILE"; printf 'Writer line.\n' > "$STUB_NOTES_FILE"
rm -f "$STUB_REPLY_SYS"
msg cap-4 "$THEM" "$ME" "ping four"
run_step "$(grep -F '"step_id":"cap-4"' "$TRAJ")"
grep -qF "LINE-21 alpha beta gamma" "$STUB_REPLY_SYS" 2>/dev/null && ok "a4: the 21st body line reaches the prompt" || bad "a4: the 21st body line reaches the prompt"
# guard: the 21-line card is under the 8192 default, so no cut marker; the
# first line's presence is guarded by a5's whole-card read instead, because
# on the unfixed step this arm flips with the pipe race
if ! grep -q "more: mem show" "$STUB_REPLY_SYS" 2>/dev/null; then ok "a4: no cut marker on a 21-line card under the default cap"; else bad "a4: no cut marker on a 21-line card under the default cap"; fi

# --- a5. a 20-line card: whole, no marker (the old window's edge) -----------
WINNAME=2026-01-05-00-00-00_e5e5e5e5_twenty-lines
for i in $(seq -w 1 20); do printf 'W%02d inside the window\n' "$((10#$i))"; done > "$WORK/card5"
reset_cards
plant_card "$WINNAME" "$WORK/card5"
printf 'Sure.\n' > "$STUB_REPLY_FILE"; printf 'Writer line.\n' > "$STUB_NOTES_FILE"
rm -f "$STUB_REPLY_SYS"
msg cap-5 "$THEM" "$ME" "ping five"
run_step "$(grep -F '"step_id":"cap-5"' "$TRAJ")"
grep -qF "W20 inside the window" "$STUB_REPLY_SYS" 2>/dev/null && grep -qF "W01 inside the window" "$STUB_REPLY_SYS" 2>/dev/null \
    && ok "a5: a 20-line card reads whole" || bad "a5: a 20-line card reads whole"
if ! grep -q "more: mem show" "$STUB_REPLY_SYS" 2>/dev/null; then ok "a5: no cut marker on a card inside the cap"; else bad "a5: no cut marker on a card inside the cap"; fi

# --- a6. a short card: whole, no marker ------------------------------------
SHTNAME=2026-01-06-00-00-00_f6f6f6f6_short-card
printf 'Three facts.\nAbout one person.\nKept whole.\n' > "$WORK/card6"
reset_cards
plant_card "$SHTNAME" "$WORK/card6"
printf 'Sure.\n' > "$STUB_REPLY_FILE"; printf 'Writer line.\n' > "$STUB_NOTES_FILE"
rm -f "$STUB_REPLY_SYS"
msg cap-6 "$THEM" "$ME" "ping six"
run_step "$(grep -F '"step_id":"cap-6"' "$TRAJ")"
grep -qF "Kept whole." "$STUB_REPLY_SYS" 2>/dev/null && ok "a6: a short card reads whole" || bad "a6: a short card reads whole"
if ! grep -q "more: mem show" "$STUB_REPLY_SYS" 2>/dev/null; then ok "a6: no cut marker on a short card"; else bad "a6: no cut marker on a short card"; fi

# --- a7. RESPONDER_PERSON_NOTES=0 still disables reading --------------------
reset_cards
plant_card "$SHTNAME" "$WORK/card6"
printf 'Sure.\n' > "$STUB_REPLY_FILE"; printf 'Writer line.\n' > "$STUB_NOTES_FILE"
rm -f "$STUB_REPLY_SYS"
msg cap-7 "$THEM" "$ME" "ping seven"
run_step "$(grep -F '"step_id":"cap-7"' "$TRAJ")" RESPONDER_PERSON_NOTES=0
if ! grep -q "What you know about" "$STUB_REPLY_SYS" 2>/dev/null; then ok "a7: RESPONDER_PERSON_NOTES=0 disables the notes read"; else bad "a7: RESPONDER_PERSON_NOTES=0 disables the notes read"; fi

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
