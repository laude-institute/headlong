#!/usr/bin/env bash
# tests/test_prompt_cut_markers.sh — the three unmarked cuts in the wake
# prompt's assembly path, found by the 2026-10-17 full-path sweep: the
# Runtime line gloss cuts the commit subject at 60 characters
# (thinkers/_lib/common.sh, _runtime_line), the scheduled-goal title cuts
# the summary at 60 (_schedule_signals), and the related-memories teaser
# cuts the first body line at 140 (_related_memories). Each must mark what
# it drops with the remaining count and the route to the rest, the shape
# the goal-body marker introduced (be080b0): "(+N more: <route>)".
#
# Born red on eab04ad 2026-10-18: the four marker arms fail while every
# bound arm (the take stays bounded, the tail is dropped, short inputs carry
# no marker, the Runtime line stays one line) passes, so the suite separates
# "the cut happens" from "the cut is visible".
#
# Usage: tests/test_prompt_cut_markers.sh
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
has()   { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "missing '$3' in: $2"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1" "unexpected '$3' in: $2"; else ok "$1"; fi; }

command -v jq  >/dev/null 2>&1 || { echo "FAIL jq not found";  exit 1; }
command -v git >/dev/null 2>&1 || { echo "FAIL git not found"; exit 1; }

WORK=$(mktemp -d)
trap 'chmod -R u+w "$WORK" 2>/dev/null; cd /; rm -rf "$WORK"' EXIT

# ── Part 1: the Runtime line gloss ──────────────────────────────────────────
# A throwaway checkout with a stub shellm on PATH (as test_runtime_boundary_
# line.sh) and the one variable this part owns: the commit subject, 100 chars.
SUBJ1="$(printf 'x%.0s' {1..90})tailwordAB"
ROOT="$WORK/checkout"
mkdir -p "$ROOT/bin" "$WORK/ident/thinkers"
printf '#!/usr/bin/env bash\nexit 0\n' > "$ROOT/bin/shellm"; chmod +x "$ROOT/bin/shellm"
git -C "$ROOT" init -q
git -C "$ROOT" -c user.email=t@t -c user.name=t add -A
git -C "$ROOT" -c user.email=t@t -c user.name=t commit -qm "$SUBJ1"

rline() {
    ( export PATH="$ROOT/bin:$PATH" IDENTITY_DIR="$WORK/ident"
      source "$REPO/thinkers/_lib/common.sh" >/dev/null 2>&1
      _runtime_line )
}
out=$(rline)
has   "runtime line marks the subject cut"    "$out" "(+40 more"
has   "runtime marker names the route"        "$out" "git log -1"
hasnt "runtime take is bounded, tail dropped" "$out" "tailwordAB"
[[ "$(wc -l <<< "$out")" -eq 1 ]] && ok "runtime line stays one line" || bad "runtime line stays one line" "$(wc -l <<< "$out") lines"

ROOT="$WORK/checkout2"
mkdir -p "$ROOT/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$ROOT/bin/shellm"; chmod +x "$ROOT/bin/shellm"
git -C "$ROOT" init -q
git -C "$ROOT" -c user.email=t@t -c user.name=t add -A
git -C "$ROOT" -c user.email=t@t -c user.name=t commit -qm "stub checkout"
out=$(rline)
hasnt "short subject carries no marker" "$out" "(+"

# ── Part 2: the scheduled-goal title ────────────────────────────────────────
# The harness of test_scheduled_goals.sh part 3: a pinned clock and a chat
# env, with the goal files written directly so the summary length is this
# part's own variable, independent of what mem add derives.
ME=tstp
TRAJ_ID2="cafe0000-0000-0000-0000-00000000cens"
ID2="$WORK/ident2"
mkdir -p "$ID2/trajectories/$TRAJ_ID2" "$ID2/memories"
TRAJ2="$ID2/trajectories/$TRAJ_ID2/trajectory.jsonl"
export IDENTITY_NAME="$ME" TRAJ_DIR="$ID2/trajectories" TRAJ_ID="$TRAJ_ID2" MEM_DIR="$ID2/memories"
export HOME="$WORK/home"; mkdir -p "$HOME"
printf 'default_send_from=%s\n' "$ME" > "$HOME/.chatrc"
export CHATRC="$HOME/.chatrc"
printf '{"step_id":"%s","type":"trajectory","ts":"2026-01-01T00:00:00.000Z"}\n' "$TRAJ_ID2" > "$TRAJ2"

SUMM1="$(printf 'y%.0s' {1..90})tailwordCD"
printf -- '---\nid: cafef00d\nsummary: %s\ntype: goal\ncreated: 2026-08-05 00:00:00\nschedule: 09:00\ntz: UTC\n---\n\nFirst goal body.\n' "$SUMM1" > "$MEM_DIR/goal-long-summary.md"
printf -- '---\nid: abba1234\nsummary: Short duty title\ntype: goal\ncreated: 2026-08-06 00:00:00\nschedule: 10:00\ntz: UTC\n---\n\nSecond goal body.\n' > "$MEM_DIR/goal-short-summary.md"

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

signals() {
    FAKE_LOCAL="$1" PATH="$WORK/fakebin:$PATH" bash -c '
        set -euo pipefail
        source "$0/thinkers/_lib/common.sh" >/dev/null 2>&1 || true
        _schedule_signals "$MEM_DIR"' "$REPO"
}
DAY2=$(/bin/date -u +%Y-%m-%d)

out=$(signals "$DAY2 09:05")
has   "due line marks the title cut"        "$out" "(+40 more: mem show cafef00d"
hasnt "title take is bounded, tail dropped"  "$out" "tailwordCD"

out=$(signals "$DAY2 10:05")
l2=$(grep -F 'Short duty title' <<< "$out" || true)
[[ -n "$l2" ]] && ok "short summary keeps its own due line" || bad "short summary keeps its own due line" "$out"
if grep -qF -- "(+" <<< "$l2"; then bad "short summary carries no marker" "$l2"; else ok "short summary carries no marker"; fi

# ── Part 3: the related-memories teaser ─────────────────────────────────────
export MEM_DIR="$WORK/mem3"; mkdir -p "$MEM_DIR"
NAME3="2026-08-05-00-00-00_m1_markerfix"
B3="$(printf 'quokka zephyr %.0s' {1..13})END9z"
printf -- '---\nid: m1\nsummary: s\ntype: fact\ncreated: 2026-08-05 00:00:00\n---\n\n%s\n' "$B3" > "$MEM_DIR/$NAME3.md"
NAME4="2026-08-06-00-00-00_m2_smallfix"
printf -- '---\nid: m2\nsummary: s\ntype: fact\ncreated: 2026-08-06 00:00:00\n---\n\nquokka zephyr small duty\n' > "$MEM_DIR/$NAME4.md"

lib() { ( source "$REPO/thinkers/_lib/common.sh"; "$@" ); }
r=$(lib _related_memories "quokka zephyr" "" 3)
exp3=$(( ${#B3} - 140 ))
has   "teaser marks the cut"               "$r" "(+$exp3 more: mem show $NAME3"
hasnt "teaser take is bounded, tail dropped" "$r" "END9z"
l4=$(grep -F "$NAME4" <<< "$r" || true)
[[ -n "$l4" ]] && ok "short teaser keeps its own line" || bad "short teaser keeps its own line" "$r"
if grep -qF -- "(+" <<< "$l4"; then bad "short teaser carries no marker" "$l4"; else ok "short teaser carries no marker"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
