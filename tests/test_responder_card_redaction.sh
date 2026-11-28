#!/usr/bin/env bash
# tests/test_responder_card_redaction.sh — card digits never enter the log
# through the responder's own writes (2026-09-21 card-in-log incident).
#
# Usage: tests/test_responder_card_redaction.sh
#
# The inbound message step keeps its raw content (it is the record). What
# this test pins: every string the responder itself appends or sends — the
# reply, the deferral `action` step, every observation quoting the message
# (including the failure exits: timeout, token cap, broken JSON, raw JSON),
# and person notes — has card-shaped and cvv/expiry-shaped digits replaced
# with [card redacted]/[redacted]. Dates, times, party sizes, confirmation
# numbers, phone numbers, and zips pass through untouched. The person-notes
# case drives a real notes write (nonempty history, foreground writer) and
# a control run with the redaction stripped proves the assertion has teeth.
# Stubbed llm and chat; no LLM calls, no docker.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID THINK_CONTEXT_TAIL THINK_MODEL MONOLITH_REPLY_MODEL 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
RESPONDER="$REPO/thinkers/responder/step"

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
TRAJ_ID="cafe0000-0000-0000-0000-0000000000cd"
mkdir -p "$ID/memories" "$ID/trajectories/$TRAJ_ID" "$ID/run"
printf 'name=%s\ncreated=test\nroot_trajectory=%s\n' "$ME" "$TRAJ_ID" > "$ID/info.txt"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"
printf 'test-token\n' > "$ID/run/dispatcher.token"

mkdir -p "$WORK/stub"
cat > "$WORK/stub/llm" <<'STUB'
#!/usr/bin/env bash
# Serves $STUB_REPLY_FILE for the reply call. For the person-notes call
# (recognizable by its -s system prompt containing 'notes'), serves
# $STUB_NOTES_FILE so notes can carry digits too. STUB_LLM_MODE=timeout or
# =truncated prints the failure shape bin/llm reports on stderr, with no
# usable stdout, so the failure exits run deterministically.
for _a in "$@"; do :; done
_prev=""
for _a in "$@"; do [[ "$_prev" == "-s" ]] && _sys="$_a"; _prev="$_a"; done
if printf '%s' "${_sys:-}" | grep -q 'private notes about one person'; then cat "$STUB_NOTES_FILE"
elif [[ "${STUB_LLM_MODE:-}" == timeout ]]; then printf 'curl: (28) timed out\n' >&2; exit 1
elif [[ "${STUB_LLM_MODE:-}" == truncated ]]; then printf 'output truncated at max_tokens\n' >&2; exit 1
else cat "$STUB_REPLY_FILE"; fi
STUB
cat > "$WORK/stub/chat" <<'STUB'
#!/usr/bin/env bash
# Records every invocation, and the reply body (stdin when piped). The
# history call serves $STUB_HISTORY_FILE when set, else no history.
printf 'CHATCALL: %s\n' "$*" >> "$STUB_CALLS_FILE"
if [[ "$1" == history ]]; then
    if [[ -n "${STUB_HISTORY_FILE:-}" ]]; then cat "$STUB_HISTORY_FILE"; else printf '[]\n'; fi
else cat > "${STUB_SENT_FILE:-/dev/null}"; fi
exit 0
STUB
chmod +x "$WORK/stub/llm" "$WORK/stub/chat"
export STUB_REPLY_FILE="$WORK/reply" STUB_NOTES_FILE="$WORK/notes" STUB_SENT_FILE="$WORK/sent" STUB_CALLS_FILE="$WORK/calls"

ENV_COMMON=(PATH="$WORK/stub:$REPO/bin:$REPO/tools:$PATH" IDENTITY_DIR="$ID" IDENTITY_NAME="$ME"
    MEM_DIR="$ID/memories" TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID" HOME="$WORK/home"
    SHELLM_MODEL=stub-model THINK_CONTEXT_TAIL=30 RESPONDER_PERSON_NOTES=0 MONOLITH_TIERED_MEMORY=0)
run_responder() {  # run_responder <trigger json> [extra env assignments...]
    local _trig="$1"; shift
    : > "$STUB_SENT_FILE"
    printf '%s' "$_trig" | env "${ENV_COMMON[@]}" "$@" "$RESPONDER" >> "$WORK/step.log" 2>&1
}
now() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }

hdr() { printf '{"step_id":"hdr","type":"trajectory","ts":"%s"}\n' "$(now)" >> "$TRAJ"; }

# --- 1. reply: the sent text carries no card digits ------------------------
: > "$TRAJ"; hdr
printf '{"step_id":"trig-1","type":"message","from":"%s","to":"%s","content":"use 4242 4242 4242 4242 exp 12/28 cvv 411 for Bestia","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf 'Got it, booking with 4242 4242 4242 4242 now.\n' > "$STUB_REPLY_FILE"
run_responder "$(grep -F '"step_id":"trig-1"' "$TRAJ")"
if grep -q '4242' "$STUB_SENT_FILE"; then bad "reply: card digits redacted in sent text" "$(cat "$STUB_SENT_FILE")"; else ok "reply: card digits redacted in sent text"; fi
_sent1=$(cat "$STUB_SENT_FILE")
if printf '%s' "$_sent1" | grep -q 'book' && printf '%s' "$_sent1" | grep -q 'redacted'; then ok "reply: text survives (not blanked)"; else bad "reply: text survives (not blanked)" "$_sent1"; fi

# --- 2. observations: no digit restatement from the trigger ----------------
: > "$TRAJ"; hdr
printf '{"step_id":"trig-2","type":"message","from":"%s","to":"%s","content":"card is 378282246310005, amex","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf 'NO_REPLY\n' > "$STUB_REPLY_FILE"
run_responder "$(grep -F '"step_id":"trig-2"' "$TRAJ")"
if grep -q '378282246310005' "$TRAJ" && ! jq -r 'select(.type=="observation" or .type=="action" or .type=="reply_claim") | .content // empty' "$TRAJ" | grep -q '378282246310005'; then ok "observations: no amex restatement"; else bad "observations: no amex restatement" "$(jq -c 'select(.type=="observation")' "$TRAJ" | head -3)"; fi

# --- 3. deferral: action.request and the holding reply stay clean ----------
: > "$TRAJ"; hdr
printf '{"step_id":"trig-3","type":"message","from":"%s","to":"%s","content":"book Bestia with 4111-1111-1111-1111 cvv 777","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf 'DEFER: book Bestia with card 4111-1111-1111-1111 exp 04/27 cvv 777 for Nov 7\nLet me get that booked.\n' > "$STUB_REPLY_FILE"
run_responder "$(grep -F '"step_id":"trig-3"' "$TRAJ")"
action_req=$(jq -r 'select(.type=="action") | .request // empty' "$TRAJ")
if printf '%s' "$action_req" | grep -q '4111'; then bad "deferral: action.request redacted" "$action_req"; else ok "deferral: action.request redacted"; fi
if printf '%s' "$action_req" | grep -q 'Bestia'; then ok "deferral: request text survives (work is readable)"; else bad "deferral: request text survives (work is readable)" "$action_req"; fi
if grep -q '777' "$TRAJ" && ! jq -r 'select(.type=="observation") | .content // empty' "$TRAJ" | grep -q '777'; then ok "deferral: cvv redacted in observations"; else bad "deferral: cvv redacted in observations" "$(jq -c 'select(.type=="observation")' "$TRAJ" | head -2)"; fi
# the message step itself keeps its raw content (the record)
if jq -r 'select(.type=="message" and .step_id=="trig-3") | .content' "$TRAJ" | grep -q '4111-1111-1111-1111'; then ok "record: inbound message step keeps raw content"; else bad "record: inbound message step keeps raw content"; fi

# --- 4. benign numbers pass through ---------------------------------------
: > "$TRAJ"; hdr
printf '{"step_id":"trig-4","type":"message","from":"%s","to":"%s","content":"Bestia Nov 7 2026 6pm party of 2 conf 2110728612 zip 94110","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf 'Booked Bestia Nov 7 2026 6pm party of 2 conf 2110728612 zip 94110, reply 2110728612.\n' > "$STUB_REPLY_FILE"
run_responder "$(grep -F '"step_id":"trig-4"' "$TRAJ")"
sent=$(cat "$STUB_SENT_FILE")
if printf '%s' "$sent" | grep -q '2110728612' && printf '%s' "$sent" | grep -q '94110'; then ok "benign: confirmation number and zip survive"; else bad "benign: confirmation number and zip survive" "$sent"; fi

# --- 5. person notes: the write path itself stays clean ---------------------
# The writer only runs with history to summarize; the old stub returned none,
# so the notes call returned before writing anything and the assertion passed
# with no file to check. Here the chat stub serves one history row and the
# writer runs in the foreground, so a person memory is actually written.
: > "$TRAJ"; hdr
printf '{"step_id":"trig-5","type":"message","from":"%s","to":"%s","content":"my card 5555 5555 5555 5555 for bookings","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf 'ok\n' > "$STUB_REPLY_FILE"
printf 'notes: andy books tables, card 5555 5555 5555 5555\n' > "$STUB_NOTES_FILE"
# These synthetic shapes are not exported, so only shape masking catches them.
# The arbitrary value checks literal environment masking in the real writer.
_note_secrets=(
    "$(printf '%s' ghp_ AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA)"
    "$(printf '%s' xoxb- abcdefghijklmnopqrstuv)"
    "$(printf '%s' npm_ abcdefghijklmnopqrstuvwxyz)"
    "$(printf '%s' sk_live_ abcdefghijklmnopqrstuv)"
    'PRIVATE_BODY_notes_fixture'
)
export TWILIO_AUTH_TOKEN='notes-value*[fixture]?end'
_note_secrets+=("$TWILIO_AUTH_TOKEN")
printf '%s\n' "${_note_secrets[0]}" "${_note_secrets[1]}" \
    "${_note_secrets[2]}" "${_note_secrets[3]}" \
    '-----BEGIN PRIVATE KEY-----' "${_note_secrets[4]}" \
    '-----END PRIVATE KEY-----' "$TWILIO_AUTH_TOKEN" 'benign notes after credentials' >> "$STUB_NOTES_FILE"

STUB_HISTORY_FILE="$WORK/history"
printf '[{"ts":"2026-09-22T09:00:00.000Z","from":"%s","content":"my card 5555 5555 5555 5555 for bookings"}]\n' "$THEM" > "$STUB_HISTORY_FILE"
run_responder "$(grep -F '"step_id":"trig-5"' "$TRAJ")" RESPONDER_PERSON_NOTES=1 RESPONDER_PERSON_NOTES_SYNC=1 STUB_HISTORY_FILE="$STUB_HISTORY_FILE"
_pn=$(grep -l '^type: person' "$ID/memories"/*.md 2>/dev/null | head -1)
if [[ -n "$_pn" ]]; then ok "person notes: a person memory is written (the write path runs)"; else bad "person notes: a person memory is written (the write path runs)" "$(tail -3 "$WORK/step.log")"; fi
if [[ -n "$_pn" ]] && grep -q 'andy books tables' "$_pn"; then ok "person notes: ordinary note text survives"; else bad "person notes: ordinary note text survives" "$(cat "$_pn" 2>/dev/null)"; fi
if [[ -n "$_pn" ]] && grep -q '\[card redacted\]' "$_pn" && ! grep -q '5555 5555' "$_pn"; then ok "person notes: card digits replaced by the marker"; else bad "person notes: card digits replaced by the marker" "$(cat "$_pn" 2>/dev/null)"; fi
for _secret in "${_note_secrets[@]}"; do
    if [[ -n "$_pn" ]] && ! grep -qF "$_secret" "$_pn" && grep -q 'benign notes after credentials' "$_pn"; then
        ok 'person notes: credential removed and surrounding text kept'
    else
        bad 'person notes: credential removed and surrounding text kept'
    fi
done
# Control: the same run with the redaction pipe stripped must store the
# digits, so the assertions above fail when the redaction is bypassed.
# The step sources ../_lib/common.sh relative to its own path, so the
# stripped copy must keep that directory shape, not sit alone in $WORK.
_noredact_dir="$WORK/thinkers-no-redact"
mkdir -p "$_noredact_dir/responder"
cp -r "$REPO/thinkers/_lib" "$_noredact_dir/"
cp "$REPO"/thinkers/responder/* "$_noredact_dir/responder/"
# No in-place sed here: BSD sed takes a backup-suffix argument after -i,
# so GNU's bare form made the Mac runner treat the script as the suffix
# and the file path as the command, leaving the stripped copy identical
# to the real step. Stream to the file instead; portable everywhere.
sed 's#| _redact_keys | head -n 20#| head -n 20#' "$REPO/thinkers/responder/step" > "$_noredact_dir/responder/step"
chmod +x "$_noredact_dir/responder/step"
rm -f "$ID/memories"/*.md
# Fresh trigger step: the idempotency guard skips a trigger that already
# has a stamped reply, and the first run stamped one for trig-5.
printf '{"step_id":"trig-5b","type":"message","from":"%s","to":"%s","content":"my card 5555 5555 5555 5555 for bookings","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf '%s' "$(grep -F '"step_id":"trig-5b"' "$TRAJ")" | env "${ENV_COMMON[@]}" RESPONDER_PERSON_NOTES=1 RESPONDER_PERSON_NOTES_SYNC=1 STUB_HISTORY_FILE="$STUB_HISTORY_FILE" "$_noredact_dir/responder/step" >> "$WORK/step.log" 2>&1
_pn2=$(grep -l '^type: person' "$ID/memories"/*.md 2>/dev/null | head -1)
if [[ -n "$_pn2" ]] && grep -q '5555 5555 5555 5555' "$_pn2"; then ok "control: with the redaction stripped the same notes store the digits"; else bad "control: with the redaction stripped the same notes store the digits" "$(cat "$_pn2" 2>/dev/null)"; fi

for _secret in "${_note_secrets[@]}"; do
    if [[ -n "$_pn2" ]] && grep -qF "$_secret" "$_pn2"; then
        ok 'control: unfiltered notes retain the credential fixture'
    else
        bad 'control: unfiltered notes retain the credential fixture'
    fi
done
unset TWILIO_AUTH_TOKEN

echo
# --- 6..9. failure exits quote the trigger through the redacted excerpt -----
# The timeout, token-cap, broken-JSON and raw-JSON exits each append an
# observation quoting the message; each quote must be the redacted excerpt
# while the inbound message step keeps its raw content (it is the record).
_fail_obs_clean() {  # _fail_obs_clean <trig-id> <label> <sensitive-egrep> <kind-words>
    local _tid="$1" _label="$2" _sens="$3" _kind="$4" _obses _raw
    _raw=$(jq -r --arg t "$_tid" 'select(.type=="message" and .step_id==$t) | .content // empty' "$TRAJ")
    if printf '%s' "$_raw" | grep -qE "$_sens"; then ok "$_label: the inbound message step keeps its raw content"; else bad "$_label: the inbound message step keeps its raw content" "$_raw"; fi
    _obses=$(jq -r 'select(.type=="observation") | .content // empty' "$TRAJ")
    if printf '%s' "$_obses" | grep -q "$_kind"; then ok "$_label: the failure observation is appended"; else bad "$_label: the failure observation is appended" "$(jq -c 'select(.type=="observation")' "$TRAJ" | head -2)"; fi
    if printf '%s' "$_obses" | grep -qE "$_sens"; then bad "$_label: the observation omits card, cvv, and expiry" "$(printf '%s' "$_obses" | grep -E "$_sens" | head -2)"; else ok "$_label: the observation omits card, cvv, and expiry"; fi
    if printf '%s' "$_obses" | grep -q '\[card redacted\]'; then ok "$_label: the observation quotes the redacted excerpt"; else bad "$_label: the observation quotes the redacted excerpt" "$(printf '%s' "$_obses" | head -1)"; fi
}

# 6. timeout: nothing came back and the call itself ran out of time.
: > "$TRAJ"; hdr
printf '{"step_id":"trig-6","type":"message","from":"%s","to":"%s","content":"pay with 4111 1111 1111 1111 exp 10/28 cvv 999 today","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf 'ok\n' > "$STUB_REPLY_FILE"
run_responder "$(grep -F '"step_id":"trig-6"' "$TRAJ")" STUB_LLM_MODE=timeout RESPONDER_MAX_TIME=45
_fail_obs_clean trig-6 "timeout exit" '4111|999|10/28' 'longer than'

# 7. token cap: the whole budget spent with nothing usable.
: > "$TRAJ"; hdr
printf '{"step_id":"trig-7","type":"message","from":"%s","to":"%s","content":"amex card 378282246310005 exp 04/27 cvv 777 billed monthly","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf 'ok\n' > "$STUB_REPLY_FILE"
run_responder "$(grep -F '"step_id":"trig-7"' "$TRAJ")" STUB_LLM_MODE=truncated RESPONDER_MAX_TOKENS=1000
_fail_obs_clean trig-7 "token-cap exit" '378282246310005|777|04/27' 'token budget'

# 8. broken structured JSON: an object that does not parse is never sent.
: > "$TRAJ"; hdr
printf '{"step_id":"trig-8","type":"message","from":"%s","to":"%s","content":"book with 4242 4242 4242 4242 exp 12/28 cvv 411 tonight","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf '{"broken":\n' > "$STUB_REPLY_FILE"
run_responder "$(grep -F '"step_id":"trig-8"' "$TRAJ")" RESPONDER_STRUCTURED=1
_fail_obs_clean trig-8 "broken-JSON exit" '4242|411|12/28' 'broken JSON object'

# 9. raw JSON object instead of a message: never sent, surfaced as a failure.
: > "$TRAJ"; hdr
printf '{"step_id":"trig-9","type":"message","from":"%s","to":"%s","content":"charge 5555 5555 5555 5555 exp 01/29 cvv 123 today","ts":"%s","source":"chat"}\n' "$THEM" "$ME" "$(now)" >> "$TRAJ"
printf '{"action":"reply","message":"done"}\n' > "$STUB_REPLY_FILE"
run_responder "$(grep -F '"step_id":"trig-9"' "$TRAJ")" RESPONDER_STRUCTURED=0
_fail_obs_clean trig-9 "raw-JSON exit" '5555|123|01/29' 'raw JSON object'

echo
# --- 10. portability: no GNU-only escape in the redaction expressions -----
# Stock macOS sed treats the GNU word boundary escape as no boundary at
# all, so rules anchored on it silently matched nothing there (the macOS
# bash 3.2 CI job caught it). This guard fails if it ever comes back.
_redact_body=$(sed -n '/^_redact_card()/,/^}/p' "$RESPONDER")
if printf '%s' "$_redact_body" | grep -q '\\b'; then
    bad "portability: _redact_card uses the GNU-only word boundary escape"
else
    ok "portability: _redact_card uses only POSIX boundaries"
fi

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
