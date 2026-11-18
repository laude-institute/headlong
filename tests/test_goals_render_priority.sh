#!/usr/bin/env bash
# tests/test_goals_render_priority.sh — get_goals renders the goal-family
# records owed soonest first. Before this change the render visited the
# store newest-minted first and capped at GOALS_MAX lines, so a record
# with `until` due tonight sank one position per mint and fell out of the
# window entirely, while a watch due three weeks later but minted minutes
# ago rendered in its place: recency of minting is orthogonal to
# owed-ness. The fix orders the records by `until` ascending before the
# cap, undated records after dated ones, `created` ascending as the
# tiebreak, leaving the cap, the expired filter, the and-N-more count and
# the bracket format untouched.
#
# Usage: tests/test_goals_render_priority.sh
# No LLM calls; scratch memory store only.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
line_of() { printf '%s\n' "$1" | grep -n -- "$2" | cut -d: -f1 | head -1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export MEM_DIR="$WORK/mem" PATH="$REPO/bin:$PATH"; mkdir -p "$MEM_DIR"

mk() {  # mk <name> <type> <created> <extra-frontmatter> <body>
    printf -- '---\nid: x\nsummary: s\ntype: %s\ncreated: %s\n%s---\n\n%s\n' "$2" "$3" "$4" "$5" > "$MEM_DIR/$1.md"
}

lib() { ( source "$REPO/thinkers/_lib/common.sh"; "$@" ); }

# Portable future/past dates: GNU date takes -d @epoch, BSD date takes -r
# epoch (the _epoch_utc idiom in thinkers/_lib/common.sh). macOS runners
# would reject the old `date -u -d tomorrow` as a GNU-only spelling.
ymd() {  # ymd <offset-days> -> YYYY-MM-DD
    local off="$1" e
    e=$(( $(date -u +%s) + off * 86400 ))
    date -u -d "@$e" +%Y-%m-%d 2>/dev/null || date -u -r "$e" +%Y-%m-%d
}
soon=$(ymd 1); mid=$(ymd 3); far=$(ymd 20); expired=$(ymd -1)

# Store one: the record owed soonest, minted oldest, must render inside a
# one-line cap while the later record is only counted.
mk 2026-08-01-00-00-00_a1_floor todo "2026-08-01 00:00:00" "until: $soon
" "FLOORBODY due tomorrow floor"
mk 2026-08-09-00-00-00_z9_watch todo "2026-08-09 00:00:00" "until: $far
" "WATCHBODY due in three weeks watch"
g1=$(GOALS_MAX=1 lib get_goals "$MEM_DIR")
check "owed soonest renders inside a one-line cap" grep -q FLOORBODY <<<"$g1"
check "the later record is counted, not rendered" bash -c 'grep -q WATCHBODY <<<"$1" && exit 1; grep -q "and 1 more: mem list" <<<"$1"' _ "$g1"

# Store two: full order — until ascending, created as tiebreak, undated
# after dated, expired dropped.
MEM_DIR="$WORK/mem2"; mkdir -p "$MEM_DIR"; export MEM_DIR
mk 2026-08-01-00-00-00_a1_far    todo "2026-08-01 00:00:00" "until: $far
" "WATCH3W far due"
mk 2026-08-02-00-00-00_b2_nodate todo "2026-08-02 00:00:00" "" "UNDATED first undated"
mk 2026-08-03-00-00-00_c3_mid    todo "2026-08-03 00:00:00" "until: $mid
" "SOON3D mid due"
mk 2026-08-04-00-00-00_d4_soon   todo "2026-08-04 00:00:00" "until: $soon
" "SOON1D soon due"
mk 2026-08-05-00-00-00_e5_tie    todo "2026-08-05 00:00:00" "until: $soon
" "TIE2 second same until"
mk 2026-08-06-00-00-00_f6_tie    todo "2026-08-06 00:00:00" "until: $soon
" "TIE3 third same until"
mk 2026-08-08-00-00-00_h8_un2    todo "2026-08-08 00:00:00" "" "UNTIED2 second undated"
mk 2026-08-09-00-00-00_i9_exp    todo "2026-08-09 00:00:00" "until: $expired
" "EXPIREDY already expired"
g2=$(lib get_goals "$MEM_DIR")

l_soon=$(line_of "$g2" SOON1D); l_tie2=$(line_of "$g2" TIE2); l_tie3=$(line_of "$g2" TIE3)
l_watch=$(line_of "$g2" WATCH3W); l_und=$(line_of "$g2" UNDATED); l_un2=$(line_of "$g2" UNTIED2)

check "the record owed soonest renders first" bash -c 'printf "%s\n" "$1" | head -1 | grep -q SOON1D' _ "$g2"
check "created breaks a tie on equal until" test -n "$l_soon" -a -n "$l_tie2" -a -n "$l_tie3" -a "$l_soon" -lt "$l_tie2" -a "$l_tie2" -lt "$l_tie3"
check "a dated record outranks every undated record" test -n "$l_watch" -a -n "$l_und" -a "$l_watch" -lt "$l_und"
check "undated records order by created" test -n "$l_und" -a -n "$l_un2" -a "$l_und" -lt "$l_un2"
check "an expired record never renders" bash -c '! grep -q EXPIREDY <<<"$1"' _ "$g2"
check "until renders in the bracket" grep -q "until $soon" <<<"$g2"
check "no and-more line when everything fits" bash -c '! grep -q "and [0-9]* more" <<<"$1"' _ "$g2"

g2c=$(GOALS_MAX=2 lib get_goals "$MEM_DIR")
check "the two records owed soonest fill a two-line cap" bash -c 'grep -q SOON1D <<<"$1" && grep -q TIE2 <<<"$1" && ! grep -q WATCH3W <<<"$1" && grep -q "and 5 more: mem list" <<<"$1"' _ "$g2c"

mkdir -p "$WORK/empty"; e=$(lib get_goals "$WORK/empty")
[[ "$e" == "(no goals set)" ]] && ok "no goal memories -> (no goals set)" || bad "no goal memories -> (no goals set)" "$e"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
