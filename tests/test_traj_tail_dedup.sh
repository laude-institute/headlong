#!/usr/bin/env bash
# tests/test_traj_tail_dedup.sh — the formatted tail renders a turn minted
# several times inside one run once, with a visible copy count.
#
# Usage: tests/test_traj_tail_dedup.sh
#
# Why: a wake's text fault minted one thought three times inside one run
# (2026-11-14, byte-identical content, fresh step ids, ~380ms apart). PR 252
# taught the prompt-side recent stream to collapse such bursts by
# (run_id, type, content); the formatted tail is the other render-for-context
# reader of the same rows and still showed one turn three times. The widening
# placement spec puts the same keyed dedup here: the burst collapses onto its
# first copy, which carries the copy count (keep the cap, mark the cut), while
# raw mode and the citation reads keep every copy. Raw is the default when
# piped, so every formatted assertion passes --format; --no-color keeps the
# output stable to grep.

set -uo pipefail
unset TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
is()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "FAIL jq not found"; exit 1; }

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT

export TRAJ_DIR="$WORK/trajectories"
TRAJ_ID="cafe1234-0000-0000-0000-0000000000ef"
mkdir -p "$TRAJ_DIR/$TRAJ_ID"
TRAJ="$TRAJ_DIR/$TRAJ_ID/trajectory.jsonl"
export TRAJ_ID

step() { # step <id> <type> <content> <minute> [extra json fields]
    printf '{"step_id":"%s","type":"%s","content":%s,"ts":"2026-11-14T06:%02d:00Z","source":"monolith"%s}\n' \
        "$1" "$2" "$(printf '%s' "$3" | jq -Rsa .)" "$4" "${5:-}" >> "$TRAJ"
}

: > "$TRAJ"
printf '{"type":"trajectory","step_id":"%s","ts":"2026-11-14T06:00:00Z"}\n' "$TRAJ_ID" >> "$TRAJ"
step pre  thought "a quiet opener"             59 ',"run_id":"run-aa"'
step b1  thought "one turn minted three times"  50 ',"run_id":"run-aa"'
step b2  thought "one turn minted three times"  49 ',"run_id":"run-aa"'
step b3  thought "one turn minted three times"  48 ',"run_id":"run-aa"'
step mid thought "a neighbor between bursts"    40 ',"run_id":"run-aa"'
step r1  thought "one turn minted three times"  30 ',"run_id":"run-bb"'
step n1  thought "no run id at all"             20
step n2  thought "no run id at all"             19
step post thought "a quiet closer"             10 ',"run_id":"run-aa"'

# 1. The burst renders as one line (the other run's legitimate copy keeps its
#    own line), so the burst text appears exactly twice in the window.
out=$(traj tail -n 40 --format --no-color)
n_burst=$(printf '%s\n' "$out" | grep -c "one turn minted three times" || true)
is "the three-copy burst renders as one line beside the other run's copy" "2" "$n_burst"

# 2. The survivor is marked with the raw copy count, content untouched.
if printf '%s\n' "$out" | grep -qF "(x3 copies)] one turn minted three times"; then
    ok "the collapsed line carries the copy count, content untouched"
else
    bad "the collapsed line carries the copy count" "$(printf '%s\n' "$out" | grep -F "one turn minted" | head -2)"
fi

# 3. The other run's identical content is legitimate repetition: present,
#    unmarked.
if printf '%s\n' "$out" | grep -qF "(x2 copies)"; then
    bad "no marker expected anywhere but the burst" "$(printf '%s\n' "$out" | grep -F 'x2 copies')"
else
    ok "no spurious marker on other lines"
fi
if printf '%s\n' "$out" | grep -qF "[thought, monolith] one turn minted three times"; then
    ok "the other run's copy renders unmarked"
else
    bad "the other run's copy renders unmarked" "$(printf '%s\n' "$out" | grep -F 'minted' | head -3)"
fi

# 4. Rows without a run id never merge.
n_norun=$(printf '%s\n' "$out" | grep -c "no run id at all" || true)
is "adjacent identical rows with no run id both stay" "2" "$n_norun"

# 5. The cut counts events, never copies — the order PR 252 shipped for
#    the prompt stream: dedup before the window cut, so phantom copies can
#    no longer spend the -n budget and a burst never splits at the edge.
#    Seven turns exist here; the last six render with the burst whole.
edge=$(traj tail -n 6 --format --no-color)
n_lines=$(printf '%s\n' "$edge" | grep -c . || true)
is "the -n window counts events, not raw copies" "6" "$n_lines"
if printf '%s\n' "$edge" | grep -qF "(x3 copies)"; then
    ok "a burst at the window edge stays whole and honestly marked (x3)"
else
    bad "a burst at the window edge stays whole and honestly marked (x3)" "$(printf '%s\n' "$edge" | grep -F 'minted')"
fi

# 6. -a shows the collapsed field as data.
ameta=$(traj tail -n 40 --format --no-color -a)
n_meta=$(printf '%s\n' "$ameta" | grep -c "collapsed=3" || true)
is "the -a view shows collapsed=3 on the survivor" "1" "$n_meta"

# 8. The recursive replay is the same reader: the burst collapses there too.
rout=$(traj tail -r -n 40 --format --no-color)
n_rburst=$(printf '%s\n' "$rout" | grep -c "one turn minted three times" || true)
is "the recursive tail renders the burst once beside the other run's copy" "2" "$n_rburst"
if printf '%s\n' "$rout" | grep -qF "(x3 copies)]"; then
    ok "the recursive tail carries the copy count"
else
    bad "the recursive tail carries the copy count" "$(printf '%s\n' "$rout" | grep -F 'minted' | head -2)"
fi

# 9. A filtered formatted tail is a citation read: no collapse, the asked
#    copy reachable by its own step id, no marker on it.
fout=$(traj tail -n 40 --format --no-color --filter step_id=b2)
n_f=$(printf '%s\n' "$fout" | grep -c "one turn minted three times" || true)
is "a filtered tail cites the asked copy alone" "1" "$n_f"
if printf '%s\n' "$fout" | grep -qF "(x"; then
    bad "no marker on a citation filter" "$fout"
else
    ok "no marker on a citation filter"
fi

# 7. Citation reads stay raw: every copy keeps its own step id.
raw_ids=$(traj cat "$TRAJ_ID" --raw | jq -r 'select(.type == "thought") | .step_id' | tr '\n' ' ')
is "raw cat lists all three copies" "pre b1 b2 b3 mid r1 n1 n2 post " "$raw_ids"

echo
echo "pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]]
