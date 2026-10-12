#!/usr/bin/env bash
# tests/test_goals_body_cap.sh — get_goals body cap and cut marker.
#
# get_goals used to cap every goal body at three lines with head -3 and no
# marker, silently dropping amendment paragraphs from long-lived carrier
# goals: a rider amended after the third body line never reached the wake
# prompt (found live 2026-10-08, riders seven and eight of a carrier goal
# hidden since 2026-10-07). There was also no size bound at all, so one
# huge body line would flood the whole prompt. The fix drops the line cap
# and bounds the body by characters instead (GOALS_BODY_MAX, default
# 16384, raised 2026-10-11 from the born 8192 to hold the live carrier
# whole at 11459), marking any cut with the
# remaining count and the mem show name: the cut becomes visible and the
# rest stays reachable. Arms a1 a2 a3 a6 a11 are born red on the unfixed
# lib; the rest guard neighboring behavior that must not move. No LLM
# calls, no docker. Fixture dates are computed from today, never
# baked: the a11 arm baked until 2026-10-10 at birth and rotted on that
# date, failing three arms for no defect.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID GOALS_MAX GOALS_BODY_MAX 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
# shellcheck disable=SC1091
source "$REPO/thinkers/_lib/common.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
has()  { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "missing '$3'"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1" "unexpected '$3'"; else ok "$1"; fi; }

CAP=16384
TODAY=$(date -u +%Y-%m-%d)
# BSD date (the macOS runner) has no -d: try its -v form first, fall back to GNU.
FUTURE=$(date -u -v+60d +%Y-%m-%d 2>/dev/null || date -u -d '+60 days' +%Y-%m-%d)

gdir() { local d="$1"; rm -rf "$d"; mkdir -p "$d"; printf '%s' "$d"; }
wgoal() { # wgoal <dir> <name> <until|-> <body-file>
    local d="$1" n="$2" u="$3"
    { printf -- '---\nid: %s\nsummary: %s\ntype: todo\ncreated: %s 00:00:00\n' "$n" "$n" "$TODAY"
      [ "$u" != "-" ] && printf 'until: %s\n' "$u"
      printf -- '---\n'
      cat "$4"
    } > "$d/$n.md"
}

W=$(mktemp -d); trap 'cd /; rm -rf "$W"' EXIT

# a1: a five-line body renders whole (base cuts at three lines, silently)
D=$(gdir "$W/a1")
printf 'line one MAIN1\nline two\nline three\nline four MARK4\nline five MARK5\n' > "$W/b1"
wgoal "$D" "2026-10-08-00-00-01_a1_five" "$FUTURE" "$W/b1"
out=$(get_goals "$D")
has   "a1 whole body: line four present"   "$out" "MARK4"
has   "a1 whole body: line five present"   "$out" "MARK5"
hasnt "a1 no cut marker when body fits"    "$out" "(+"

# a2: a cut body carries a marker naming the memory
D=$(gdir "$W/a2")
N="2026-10-08-00-00-02_a2_long"
{ printf '%*s' $(( CAP + 4000 )) '' | tr ' ' x; printf 'SECRETTAIL'; printf '\n'; } > "$W/b2"
wgoal "$D" "$N" "$FUTURE" "$W/b2"
out=$(get_goals "$D")
has   "a2 cut marker names the memory" "$out" "(+4010 more: mem show $N)"
hasnt "a2 no silent cut"                "$out" "SECRETTAIL"

# a3: the rendered goal is bounded
D=$(gdir "$W/a3")
printf '%*s\n' $(( CAP + 4000 )) '' | tr ' ' x > "$W/b3"
wgoal "$D" "2026-10-08-00-00-03_a3_bound" "$FUTURE" "$W/b3"
out=$(get_goals "$D")
if (( ${#out} <= CAP + 200 )); then ok "a3 rendered goal bounded to cap plus marker"; else bad "a3 rendered goal unbounded" "len ${#out}"; fi

# a4: a body exactly at the cap renders whole with no marker
D=$(gdir "$W/a4")
printf '%*sTAIL\n' $(( CAP - 5 )) '' | tr ' ' x > "$W/b4"
wgoal "$D" "2026-10-08-00-00-04_a4_edge" "$FUTURE" "$W/b4"
out=$(get_goals "$D")
has   "a4 body at cap whole" "$out" "TAIL"
hasnt "a4 no marker at cap"  "$out" "(+"

# a5: short goal rendering unchanged
D=$(gdir "$W/a5")
printf 'short body line A\nshort body line B\n' > "$W/b5"
wgoal "$D" "2026-10-08-00-00-05_a5_short" "$FUTURE" "$W/b5"
out=$(get_goals "$D")
has "a5 header shape"  "$out" "- [todo, "
has "a5 until rendered" "$out" "until $FUTURE] short body line A"
has "a5 second line"   "$out" "short body line B"

# a6: GOALS_BODY_MAX overrides the cap
D=$(gdir "$W/a6")
printf '%*sEND\n' 97 '' | tr ' ' x > "$W/b6"
wgoal "$D" "2026-10-08-00-00-06_a6_env" "$FUTURE" "$W/b6"
out=$(GOALS_BODY_MAX=64 get_goals "$D")
has   "a6 env override cuts with marker" "$out" "(+36 more: mem show 2026-10-08-00-00-06_a6_env"
hasnt "a6 tail beyond override"           "$out" "END"

# a7: no goals
D=$(gdir "$W/a7")
out=$(get_goals "$D")
has "a7 no goals line" "$out" "(no goals set)"

# a8: hidden count line over GOALS_MAX
D=$(gdir "$W/a8")
for i in 1 2 3 4 5 6 7 8 9; do
  printf 'goal body %s\n' "$i" > "$W/b8"
  wgoal "$D" "$(printf '2026-10-08-00-%02d-0%d_a8_many' "$i" "$i")" "$FUTURE" "$W/b8"
done
out=$(get_goals "$D")
has "a8 hidden count line" "$out" "and 1 more: mem list --type goal"

# a9: expired goal skipped
D=$(gdir "$W/a9")
printf 'expired body\n' > "$W/b9"
wgoal "$D" "2026-10-08-00-00-09_a9_old" "2026-01-01" "$W/b9"
out=$(get_goals "$D")
hasnt "a9 expired goal skipped"     "$out" "expired body"
has   "a9 empty renders no-goals"   "$out" "(no goals set)"

# a10: empty body skipped
D=$(gdir "$W/a10")
: > "$W/b10"
wgoal "$D" "2026-10-08-00-00-10_a10_empty" "$FUTURE" "$W/b10"
out=$(get_goals "$D")
has "a10 empty body skipped" "$out" "(no goals set)"

# a11: the carrier amendment shape renders every rider (the live red)
D=$(gdir "$W/a11")
N="2026-10-02-21-05-42_8991931f_fixture-carrier-shape"
{ printf 'Deliver the parked runtime fixes on lift, five branches named in the first line.\n\n'
  printf 'Amended 2026-10-05: a sixth branch, the find rc tolerance, rides the carrier.\n\n'
  printf 'Amended 2026-10-07: a seventh rider, the context budget cut at the cap, RIDER7.\n\n'
  printf 'Amended 2026-10-08: an eighth rider, the skills dir-list writer fix, RIDER8.\n'
} > "$W/b11"
wgoal "$D" "$N" "$FUTURE" "$W/b11"
out=$(get_goals "$D")
has "a11 seventh rider reaches the prompt" "$out" "RIDER7"
has "a11 eighth rider reaches the prompt"  "$out" "RIDER8"
has "a11 until rendered"                   "$out" "until $FUTURE]"

printf '%s passed %s failed\n' "$pass" "$fail"
if [[ $fail -eq 0 ]]; then exit 0; fi
exit 1
