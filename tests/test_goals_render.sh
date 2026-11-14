#!/usr/bin/env bash
# The goals render window: get_goals in thinkers/_lib/common.sh builds the
# active-goals block of the wake prompt. A goal body is paragraphs separated
# by blank lines, and amendments are appended as new paragraphs. Until
# 2026-10-31 the window kept the first three body lines after stripping only
# leading blanks, so every blank separator consumed a window line and every
# amendment after the first was invisible to a firing wake (measured
# 2026-10-30 on the consolidation record: six amendments past the window).
# The window must squeeze blank lines, mark elision only when lines are
# actually cut, and render the newest paragraph when it starts past the
# window, because it carries the operative state.
set -u
cd "$(dirname "$0")/.." || exit 1
# Hermetic: this suite never calls a model, and a suite run inside a wake
# inherits the wake's environment, so strip the model vars by name.
unset SHELLM_MODEL THINK_MODEL MONOLITH_REPLY_MODEL REPLY_MODEL
source thinkers/_lib/common.sh
set +e   # every arm runs; the summary decides the exit status

pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }
has() { if [[ "$2" == *"$3"* ]]; then ok; else bad "$1 (missing: $3)"; fi; }
lacks() { if [[ "$2" != *"$3"* ]]; then ok; else bad "$1 (unexpected: $3)"; fi; }

root=$(mktemp -d) || exit 1
trap 'rm -rf "$root"' EXIT

mkrec() {  # mkrec DIR NAME TYPE UNTIL BODY...
    local dir="$1" name="$2" type="$3" until="$4"; shift 4
    mkdir -p "$dir"
    {
        printf -- '---\ntype: %s\ncreated: 2026-10-30\n' "$type"
        [[ -n "$until" ]] && printf 'until: %s\n' "$until"
        printf -- '---\n'
        printf '%s\n' "$@"
    } > "$dir/$name"
}

# A: the measured defect, four single-line paragraphs (the shape of the
# live record the mitigation was landed on). All four must render; the
# render is complete, so no elision marker.
A="$root/a"; mkrec "$A" 2026-10-30-01-00-00_a1_multi.md todo "" \
    "F1 founding paragraph of the multi amendment record." "" \
    "Amendment 2026-10-30T01Z: first amendment text AMENDONE." "" \
    "Amendment 2026-10-30T02Z: second amendment text AMENDTWO." "" \
    "Amendment 2026-10-30T03Z: newest amendment text AMENDNEWEST."
out=$(get_goals "$A")
has "A founding renders"         "$out" "F1 founding paragraph"
has "A first amendment renders"  "$out" "AMENDONE"
has "A second amendment renders" "$out" "AMENDTWO"
has "A newest amendment renders" "$out" "AMENDNEWEST"
lacks "A complete render carries no marker" "$out" "... "

# B: five paragraphs. One line is elided, the marker shows the cut, the
# newest still renders.
B="$root/b"; mkrec "$B" 2026-10-30-01-00-00_b1_five.md todo "" \
    "F1 founding paragraph of the five amendment record." "" \
    "Amendment 2026-10-30T01Z: first amendment text AMENDONE." "" \
    "Amendment 2026-10-30T02Z: second amendment text AMENDMID." "" \
    "Amendment 2026-10-30T03Z: third amendment text AMENDTHREE." "" \
    "Amendment 2026-10-30T04Z: newest amendment text AMENDNEWEST."
out=$(get_goals "$B")
has "B founding renders"        "$out" "F1 founding paragraph"
has "B first amendment renders" "$out" "AMENDONE"
has "B second amendment renders" "$out" "AMENDMID"
lacks "B elided line hidden"     "$out" "AMENDTHREE"
has "B newest amendment renders" "$out" "AMENDNEWEST"
has "B elision marker present"  "$out" "... "

# C: two paragraphs fit the window with room; no marker.
C="$root/c"; mkrec "$C" 2026-10-30-02-00-00_c1_two.md todo "" \
    "F1 founding of the two paragraph record." "" \
    "Amendment 2026-10-30T01Z: only amendment AMENDONLY."
out=$(get_goals "$C")
has "C amendment renders" "$out" "AMENDONLY"
lacks "C no marker when nothing elided" "$out" "... "

# D: a whitespace-only line is a separator, not a window line.
D="$root/d"; mkrec "$D" 2026-10-30-03-00-00_d1_ws.md todo "" \
    "F1 founding of the whitespace record." "   " \
    "Amendment 2026-10-30T01Z: first after whitespace AMENDWS1." "" \
    "Amendment 2026-10-30T02Z: newest after whitespace AMENDWS2."
out=$(get_goals "$D")
has "D whitespace line does not eat the window" "$out" "AMENDWS2"

# E: leading blank lines are still stripped.
E="$root/e"; mkrec "$E" 2026-10-30-04-00-00_e1_lead.md todo "" \
    "" "F1 single line after a leading blank AMENDLEAD."
out=$(get_goals "$E")
has "E leading blank stripped" "$out" "AMENDLEAD"

# F: non goal types stay out of the goals block.
F="$root/f"; mkrec "$F" 2026-10-30-05-00-00_f1_lesson.md lesson "" "F1 lesson body LESSONBODY."
lacks "F non goal type skipped" "$(get_goals "$F")" "LESSONBODY"

# G: expired until drops, future until stays.
G="$root/g"
mkrec "$G" 2026-10-30-06-00-00_g1_expired.md todo "2020-01-01" "F1 expired body EXPBODY."
mkrec "$G" 2026-10-30-07-00-00_g2_future.md todo "2030-01-01" "F1 future body FUTBODY."
out=$(get_goals "$G")
lacks "G expired until dropped" "$out" "EXPBODY"
has "G future until kept" "$out" "FUTBODY"

# H: cap and hidden count; the window never changes the record cap.
H="$root/h"
for i in 1 2 3 4 5 6; do
    mkrec "$H" "$(printf '2026-10-30-%02d-00-00_h%d_cap.md' "$i" "$i")" todo "" "F1 cap record $i CAPBODY."
done
GOALS_MAX=2
out=$(get_goals "$H")
has "H hidden count" "$out" "and 4 more"
unset GOALS_MAX

# I: empty store.
I="$root/i"; mkdir -p "$I"
has "I no goals message" "$(get_goals "$I")" "(no goals set)"

echo "goals render window: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
