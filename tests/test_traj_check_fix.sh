#!/usr/bin/env bash
# tests/test_traj_check_fix.sh — `traj check` and `traj check --fix` agree:
# the repair removes exactly the lines the scan flags, byte-for-byte, and
# the scan sees a torn final line.
#
# Why: the scan judged each line with `jq empty`, which accepts a blank
# line and a line holding two JSON values, while --fix re-serialized the
# file through `jq -R 'fromjson? // empty'`, which drops both and
# rewrites every survivor: one bad line let --fix silently remove lines
# check had called clean, and the "removed N" report understated the
# damage. The scan also read with a bare `while IFS= read -r`, whose last
# iteration never runs on an unterminated final line, so a torn tail —
# the exact shape a crash mid-append leaves — passed as clean. Now one
# predicate decides both passes (a line is malformed iff fromjson cannot
# parse it, so a blank line and a two-value line are malformed and a bare
# null is not), the repair drops exactly the flagged line numbers with
# awk, leaving every other line byte-for-byte, and the scan reads the
# unterminated final line too.
set -uo pipefail
unset TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID 2>/dev/null
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
TRAJ_DIR="$WORK/trajectories"; export TRAJ_DIR
ID1="cafe0000-0000-0000-0000-0000000000e7"; D1="$TRAJ_DIR/$ID1"; mkdir -p "$D1"
F1="$D1/trajectory.jsonl"

# Six lines: header, an oddly spaced object, two JSON values on one line,
# a blank line, a bare null, and garbage. Malformed: lines 3, 4, 6.
cat > "$F1" <<'FIXTURE'
{"step_id":"cafe0000-0000-0000-0000-0000000000e7","type":"trajectory","ts":"2026-01-01T00:00:00Z"}
{"zeta":  1, "spaced":  2}
{"a":1}{"b":2}

null
not json
FIXTURE

out=$(traj check "$ID1" 2>&1); rc=$?
[[ $rc -eq 1 ]] && ok "check exits 1 when it flags lines" || bad "check rc" "rc=$rc"
flags=$(printf '%s\n' "$out" | grep -c 'trajectory.jsonl:') || flags=0
[[ "$flags" -eq 3 ]] && ok "check flags exactly the two-value, blank, and garbage lines" \
    || bad "flag count" "$flags flags, expected 3: $out"
printf '%s' "$out" | grep -q ':3:' && ok "check flags the two-value line (line 3)" || bad "line 3" "$out"
printf '%s' "$out" | grep -q ':4:' && ok "check flags the blank line (line 4)" || bad "line 4" "$out"
printf '%s' "$out" | grep -q ':6:' && ok "check flags the garbage line (line 6)" || bad "line 6" "$out"
printf '%s' "$out" | grep -q ':5:' && bad "bare null flagged as malformed" "$out" \
    || ok "a bare null is a JSON value, not malformed"

cp "$F1" "$F1.orig"
out=$(traj check "$ID1" --fix 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "check --fix exits 0" || bad "fix rc" "rc=$rc"
[[ $(wc -l < "$F1") -eq 3 ]] && ok "exactly the three flagged lines left the file" \
    || bad "line count" "$(wc -l < "$F1") lines, expected 3"
cmp -s <(sed -n '1p;2p;5p' "$F1.orig") "$F1" \
    && ok "survivors are byte-identical (spacing kept, bare null kept)" \
    || bad "survivors changed" "$(diff <(sed -n '1p;2p;5p' "$F1.orig") "$F1" | head -8)"
printf '%s' "$out" | grep -q 'removed 3 malformed' \
    && ok "report says removed 3 and 3 actually left" || bad "report" "$out"
out=$(traj check "$ID1" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "a repaired file checks clean" || bad "post-fix check" "$out"

# Torn final line: no trailing newline, the shape a crash mid-append leaves.
ID2="cafe0000-0000-0000-0000-0000000000e8"; D2="$TRAJ_DIR/$ID2"; mkdir -p "$D2"
F2="$D2/trajectory.jsonl"
printf '%s{"torn":' '{"step_id":"cafe0000-0000-0000-0000-0000000000e8","type":"trajectory","ts":"2026-01-01T00:00:00Z"}
' > "$F2"
cp "$F2" "$F2.orig"
out=$(traj check "$ID2" 2>&1); rc=$?
[[ $rc -eq 1 ]] && ok "check sees a torn final line" || bad "torn scan" "rc=$rc out=$out"
printf '%s' "$out" | grep -q ':2:' && ok "the torn tail is flagged as line 2" || bad "torn line number" "$out"
out=$(traj check "$ID2" --fix 2>&1)
cmp -s <(head -1 "$F2.orig") "$F2" \
    && ok "torn repair drops the tail, good line byte-identical" \
    || bad "torn repair" "$(diff <(head -1 "$F2.orig") "$F2" | head -5)"

# Clean file: --fix leaves the bytes alone and exits 0.
ID3="cafe0000-0000-0000-0000-0000000000e9"; D3="$TRAJ_DIR/$ID3"; mkdir -p "$D3"
F3="$D3/trajectory.jsonl"
printf '%s\n' '{"step_id":"cafe0000-0000-0000-0000-0000000000e9","type":"trajectory","ts":"2026-01-01T00:00:00Z"}' \
    '{"note":  "spaced"}' > "$F3"
cp "$F3" "$F3.orig"
out=$(traj check "$ID3" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "a clean file checks OK" || bad "clean rc" "$out"
traj check "$ID3" --fix >/dev/null 2>&1
cmp -s "$F3.orig" "$F3" && ok "a clean file is untouched by --fix" || bad "clean file rewritten"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
