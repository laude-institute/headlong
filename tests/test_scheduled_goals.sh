#!/usr/bin/env bash
# tests/test_scheduled_goals.sh — keys on sends and the scheduled-goal routing
# signals (design/scheduled_goals.md).
#
# Usage: tests/test_scheduled_goals.sh
#
# Part 1, `chat send --key`: the key lands on the message step and in
# `chat sent`; a second send with the same key is refused however the text is
# worded; --force overrides; a send whose delivery FAILED does not count.
# Part 2, `mem add --schedule/--tz`: the fields are written and survive
# `mem edit`. Part 3, `_schedule_signals`: with a fake `date` pinned to a known
# minute, a window is upcoming, then due, then done once its key is in the
# sent ledger; only the latest open window is due; a window past the grace
# period is missed; an expired goal is skipped; the clock line is present.
# Part 4, skipped windows: a <key>.skip record stops its window for the whole
# grace period and never reads as missed; a completion receipt still wins.
# No LLM calls, no docker.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID CHAT_REPEAT_WINDOW HEADLONG_TZ SCHEDULE_GRACE_MIN 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "missing '$3' in: $2"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1" "unexpected '$3' in: $2"; else ok "$1"; fi; }

command -v jq >/dev/null 2>&1 || { echo "FAIL jq not found"; exit 1; }

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT

ME=ada
ID="$WORK/ident"
TRAJ_ID="cafe0000-0000-0000-0000-0000000005c4"
mkdir -p "$ID/trajectories/$TRAJ_ID" "$ID/memories"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"
export IDENTITY_NAME="$ME" TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID" MEM_DIR="$ID/memories"
export HOME="$WORK/home"; mkdir -p "$HOME"
printf 'default_send_from=%s\n' "$ME" > "$HOME/.chatrc"
export CHATRC="$HOME/.chatrc"
printf '{"step_id":"%s","type":"trajectory","ts":"2026-01-01T00:00:00.000Z"}\n' "$TRAJ_ID" > "$TRAJ"

# ── Part 1: keys on sends ────────────────────────────────────────────────────
K="abcd1234/2026-09-18-0900"
out=$(chat send --to slack-C0TESTCHAN1 --key "$K" "papers, first wording" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "keyed send goes out" || bad "keyed send goes out" "$out"
got=$(tail -n 1 "$TRAJ" | jq -r '.key // ""')
[[ "$got" == "$K" ]] && ok "message step carries the key" || bad "message step carries the key" "$got"
has "chat sent shows the key" "$(chat sent 2>&1)" "[$K]"
[[ "$(chat sent --json | jq -r '.[0].key')" == "$K" ]] && ok "chat sent --json has key" || bad "chat sent --json has key"

out=$(chat send --to slack-C0TESTCHAN1 --key "$K" "papers, reworded entirely" 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "same key, new wording: refused" || bad "same key, new wording: refused" "$out"
has "refusal names the key" "$out" "$K"
out=$(chat send --to slack-C0TESTCHAN1 --key "abcd1234/2026-09-18-1700" "papers, evening" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "a different key goes out" || bad "a different key goes out" "$out"
out=$(chat send --to slack-C0TESTCHAN1 --key "$K" --force "papers, forced" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "--force overrides the key refusal" || bad "--force overrides the key refusal" "$out"

KF="abcd1234/2026-09-19-0900"
chat send --to slack-C0TESTCHAN1 --key "$KF" "will fail" >/dev/null 2>&1
fid=$(tail -n 1 "$TRAJ" | jq -r '.step_id')
printf '{"step_id":"dlv-f","type":"delivery","source":"slack-bridge","transport":"slack","trigger_step":"%s","status":"failed","reason":"channel_not_found","ts":"%s"}\n' \
    "$fid" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" >> "$TRAJ"
out=$(chat send --to slack-C0TESTCHAN2 --key "$KF" "second try, fixed address" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "a FAILED send does not use up its key" || bad "a FAILED send does not use up its key" "$out"

# ── Part 2: mem add --schedule / --tz ────────────────────────────────────────
mem add --type goal --schedule "09:00 17:00" --tz America/Los_Angeles "Daily papers for Nick" >/dev/null 2>&1
gf=$(ls "$MEM_DIR"/*.md | head -1)
grep -q '^schedule: 09:00 17:00$' "$gf" && grep -q '^tz: America/Los_Angeles$' "$gf" \
    && ok "mem add writes schedule and tz" || bad "mem add writes schedule and tz" "$(head -8 "$gf")"
out=$(mem add --type goal --schedule "9am" "bad" 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "mem add rejects a malformed schedule" || bad "mem add rejects a malformed schedule"
mem edit "$(basename "$gf" .md)" "Daily papers for Nick, edited" >/dev/null 2>&1
gf=$(ls "$MEM_DIR"/*.md | head -1)
grep -q '^schedule: 09:00 17:00$' "$gf" && grep -q '^tz: America/Los_Angeles$' "$gf" \
    && ok "schedule and tz survive mem edit" || bad "schedule and tz survive mem edit" "$(head -10 "$gf")"
GID=$(awk '/^id:/{print $2; exit}' "$gf")

# ── Part 3: _schedule_signals with a pinned clock ────────────────────────────
# A fake `date` answers the four formats the function asks for. FAKE_LOCAL is
# the local wall clock ("YYYY-MM-DD HH:MM"); the UTC date only matters for the
# `until` comparison.
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/date" <<'FAKE'
#!/usr/bin/env bash
d="${FAKE_LOCAL% *}"; t="${FAKE_LOCAL#* }"
for a in "$@"; do
    case "$a" in
        +%Y-%m-%d) echo "$d"; exit 0 ;;
        +%H:%M)    echo "$t"; exit 0 ;;
        +%Z)       echo "PDT"; exit 0 ;;
        +%A*)      echo "Friday $d $t PDT"; exit 0 ;;
        +%Y-%m-%d\ %H:%MZ) echo "$d 00:00Z"; exit 0 ;;
    esac
done
exec /bin/date "$@"
FAKE
chmod +x "$WORK/fakebin/date"

signals() {  # signals "<YYYY-MM-DD HH:MM>" -> the routing lines
    FAKE_LOCAL="$1" PATH="$WORK/fakebin:$PATH" bash -c '
        set -euo pipefail
        source "$0/thinkers/_lib/common.sh" >/dev/null 2>&1 || true
        _schedule_signals "$MEM_DIR"' "$REPO"
}
DAY=$(/bin/date -u +%Y-%m-%d)   # real today, so sends made now fall inside --since 2d

out=$(signals "$DAY 08:10")
has   "clock line is first"            "$(printf '%s\n' "$out" | head -1)" "- Now: Friday $DAY 08:10 PDT"
has   "before the first window: next"  "$out" "next window 09:00 PDT, in 0h50m"
hasnt "before the first window: not due" "$out" "DUE NOW"

out=$(signals "$DAY 09:05")
has "window open and unsent: due"  "$out" "DUE NOW"
has "due line gives the exact key" "$out" "--key $GID/$DAY-0900"

chat send --to slack-C0TESTCHAN1 --key "$GID/$DAY-0900" "morning papers" >/dev/null 2>&1
out=$(signals "$DAY 09:06")
hasnt "after the keyed send: not due"   "$out" "DUE NOW"
has   "after the keyed send: says sent" "$out" "the 09:00 window was sent at"
has   "after the keyed send: next window" "$out" "next window 17:00 PDT, in 7h54m"

out=$(signals "$DAY 17:30")
has   "second window due"              "$out" "--key $GID/$DAY-1700"
hasnt "only the latest window is due"  "$out" "$DAY-0900 <<"

out=$(SCHEDULE_GRACE_MIN=20 signals "$DAY 17:30")
hasnt "past the grace period: not due" "$out" "DUE NOW"
has   "past the grace period: missed"  "$out" "the 17:00 window was missed"
has   "no window left today: tomorrow" "$out" "next window tomorrow at 09:00 PDT"

# only the latest open window is due when two are open and unsent
mem add --type goal --schedule "06:00 07:00" "Second duty" >/dev/null 2>&1
out=$(signals "$DAY 07:30" | grep -F "Second duty")
has   "two open windows: the later is due"   "$out" "-0700"
hasnt "two open windows: the earlier is not" "$out" "-0600"

# an expired goal is skipped
mem add --type goal --until 2020-01-01 --schedule "10:00" "Expired duty" >/dev/null 2>&1
hasnt "expired goal is skipped" "$(signals "$DAY 10:30")" "Expired duty"

# ── Part 4: a window skipped on purpose (<key>.skip, bin/papers-skip) ───────
# A deliberately skipped window stops raising DUE NOW for its whole grace
# period and does not read as missed after it: nothing failed, the team asked
# for no post. A completion receipt still wins when both records exist.
unset SCHEDULE_GRACE_MIN 2>/dev/null
export PAPERS_RECEIPTS_DIR="$WORK/receipts"
mkdir -p "$PAPERS_RECEIPTS_DIR"

mem add --type goal --schedule "11:00 12:00" "Skip duty" >/dev/null 2>&1
gf=$(grep -lF 'Skip duty' "$MEM_DIR"/*.md | head -1)
SKID=$(awk '/^id:/{print $2; exit}' "$gf")
[[ -n "$SKID" ]] && ok "skip test goal created" || bad "skip test goal created" "no id in $gf"

skipwrite() {  # skipwrite <HHMM> <reason>
    printf 'key=%s/%s-%s\nskipped=%s\nreason=%s\n' \
        "$SKID" "$DAY" "$1" "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" \
        > "$PAPERS_RECEIPTS_DIR/${SKID}_${DAY}-$1.skip"
}

skipwrite 1100 "cap spent: the 09:00 pair used the two-a-day limit"
out=$(signals "$DAY 11:05" | grep -F "Skip duty")
has   "a skipped window is not due"    "$out" "the 11:00 window was skipped on purpose: cap spent"
hasnt "a skipped window does not fire" "$out" "DUE NOW"

export SCHEDULE_GRACE_MIN=20
out=$(signals "$DAY 11:55" | grep -F "Skip duty")
unset SCHEDULE_GRACE_MIN
has   "past grace a skip is not a miss" "$out" "the 11:00 window was skipped on purpose"
hasnt "past grace a skip is not a miss" "$out" "was missed"

skipwrite 1200 ""
out=$(signals "$DAY 12:05" | grep -F "Skip duty")
has   "a skip with no reason still stops the window" "$out" "skipped on purpose: no reason given"
hasnt "a skip with no reason does not fire"          "$out" "DUE NOW"

# a completion receipt wins over a skip record when both somehow exist
printf 'key=%s/%s-1200\nsent=%s\nids=2609.29647\n' "$SKID" "$DAY" \
    "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$PAPERS_RECEIPTS_DIR/${SKID}_${DAY}-1200.receipt"
out=$(signals "$DAY 12:06" | grep -F "Skip duty")
has   "a receipt wins over a skip"      "$out" "the 12:00 window was sent at"
hasnt "a receipt is not called skipped" "$out" "the 12:00 window was skipped"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
