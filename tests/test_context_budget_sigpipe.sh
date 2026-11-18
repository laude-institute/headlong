#!/usr/bin/env bash
# Context budget-overflow SIGPIPE arms, fix/context-budget-sigpipe (2026-10-11).
#
# bin/context's --max-bytes overflow branch cut the rendered prompt with
# `printf '%s' "$best_result" | head -c "$CTX_MAX_BYTES"` under
# set -euo pipefail. head stops reading at the cap; when the render is
# bigger than the pipe buffer the printf producer takes SIGPIPE after the
# truncated bytes were already delivered, and pipefail kills the script
# rc 1 before the [budget exceeded] note: a too-dense trajectory exits
# nonzero with its output delivered, which an errexit caller reads as a
# failed prompt build. Live shape from the 2026-10-07 head-cut sweep: a
# 200KB render cut at 50KB delivered all 50000 bytes and died rc 1 with
# no note.
#
# The fix drains the pipe through awk (reads every record, prints only
# the first CTX_MAX_BYTES bytes) so no producer ever writes into a closed
# pipe, the same shape as the mem prefilter and workspace section fixes;
# LC_ALL=C keeps the cut byte-exact against the head -c it replaces.
#
# Arms 2, 3, 5 are born red on main (rc 1, no note) and green at this
# branch's tip, byte-identical to the head -c cut. Arms 1, 4, 6 are
# regression guards: 4 documents that main already delivers the exact cut
# bytes before dying (the failure is only the exit code), 6 proves the
# budget search still fits a smaller render under the cap with no note.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CONTEXT="$ROOT/bin/context"
PATH="$ROOT/bin:$PATH"
unset TRAJ_DIR TRAJ_ID 2>/dev/null || true

PASS=0 FAIL=0
W=$(mktemp -d) || exit 1
trap 'rm -rf "$W"' EXIT
PROD='--assistant-types reasoning,final --user-types prompt,shell-output'
NOTE='budget exceeded: trajectory too dense'

# control: one short prompt row
mkdir -p "$W/control"
printf '%s\n' '{"type":"prompt","content":"small wake","step_id":"c-000"}' \
    > "$W/control/trajectory.jsonl"

# dense: one 200000-byte prompt row, rendered whole by --full-types prompt,
# so every binary-search limit renders over the cap and the overflow cut
# fires on a result far past the 64KB pipe buffer.
mkdir -p "$W/dense"
python3 - "$W/dense/trajectory.jsonl" <<'PYEOF'
import json, sys
row = {"type": "prompt", "content": "x" * 200000, "step_id": "d-000"}
open(sys.argv[1], "w").write(json.dumps(row) + "\n")
PYEOF

# multibyte: 100000 two-byte characters (200000 bytes); a byte cut at an
# odd offset lands inside a character, where char counting (a missing
# LC_ALL=C) would drift from byte counting.
mkdir -p "$W/mb"
python3 - "$W/mb/trajectory.jsonl" <<'PYEOF'
import json, sys
row = {"type": "prompt", "content": "é" * 100000, "step_id": "m-000"}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write(json.dumps(row, ensure_ascii=False) + "\n")
PYEOF

# fits: twenty 20000-byte shell-output rows (400KB whole, about 42KB at
# the default 2048 field limit), so the binary search finds a fitting
# limit and the overflow cut never fires.
mkdir -p "$W/fits"
python3 - "$W/fits/trajectory.jsonl" <<'PYEOF'
import json, sys
with open(sys.argv[1], "w") as f:
    for i in range(20):
        f.write(json.dumps({"type": "shell-output", "stdout": "y" * 20000,
                            "exit": 0, "step_id": "f-%03d" % i}) + "\n")
PYEOF

run_ctx() {  # run_ctx <fixture> <flags...>: rc is context's rc; stdout in OUT, stderr in ERR
    OUT="$W/out.json"; ERR="$W/err.txt"
    "$CONTEXT" --traj_dir "$W" "$1" "${@:2}" > "$OUT" 2> "$ERR"
}
bytes_out() { LC_ALL=C wc -c < "$OUT" | tr -d '[:space:]'; }

arm() {  # arm <name> <fn>
    if "$2"; then PASS=$((PASS+1)); echo "PASS $1"
    else FAIL=$((FAIL+1)); echo "FAIL $1"; fi
}

# whole renders for the prefix comparisons (no --max-bytes: plain printf)
"$CONTEXT" --traj_dir "$W" dense $PROD --full-types prompt > "$W/dense-full.json" 2>/dev/null
"$CONTEXT" --traj_dir "$W" mb $PROD --full-types prompt > "$W/mb-full.json" 2>/dev/null
dense_full_bytes=$(LC_ALL=C wc -c < "$W/dense-full.json" | tr -d '[:space:]')

control_whole_and_silent() {
    run_ctx control $PROD --max-bytes 100000 || return 1
    grep -q "$NOTE" "$ERR" && return 1
    "$CONTEXT" --traj_dir "$W" control $PROD > "$W/control-nomax.json" 2>/dev/null || return 1
    cmp -s "$OUT" "$W/control-nomax.json"
}
dense_survives_and_notes() {
    run_ctx dense $PROD --full-types prompt --max-bytes 50000 || return 1
    grep -q "$NOTE" "$ERR"
}
dense_cut_exact_bytes() {
    run_ctx dense $PROD --full-types prompt --max-bytes 50000 || return 1
    [ "$(bytes_out)" -eq 50000 ]
}
dense_cut_is_prefix() {
    # byte identity with the head -c cut, independent of the exit code:
    # main delivers these bytes too, then dies; the rc failure is carried
    # by the two arms above.
    run_ctx dense $PROD --full-types prompt --max-bytes 50000
    head -c 50000 "$W/dense-full.json" > "$W/dense-exp.bin"
    cmp -s "$OUT" "$W/dense-exp.bin"
}
mb_cut_byte_exact() {
    run_ctx mb $PROD --full-types prompt --max-bytes 50001 || return 1
    [ "$(bytes_out)" -eq 50001 ] || return 1
    head -c 50001 "$W/mb-full.json" > "$W/mb-exp.bin"
    cmp -s "$OUT" "$W/mb-exp.bin"
}
search_fits_without_note() {
    run_ctx fits $PROD --max-bytes 100000 || return 1
    grep -q "$NOTE" "$ERR" && return 1
    local b; b=$(bytes_out)
    [ "$b" -le 100000 ] && [ "$b" -gt 40000 ]
}

arm "control: small render passes whole with no note" control_whole_and_silent
arm "dense cut survives rc 0 and notes the budget (born red on main)" dense_survives_and_notes
arm "dense cut delivers exactly the cap in bytes (born red on main)" dense_cut_exact_bytes
arm "dense cut bytes are the head -c prefix of the whole render" dense_cut_is_prefix
arm "multibyte cut is byte-exact at an odd offset (born red on main)" mb_cut_byte_exact
arm "budget search fits a smaller render without the note" search_fits_without_note
echo "context-budget arms: $PASS passed, $FAIL failed (dense render $dense_full_bytes bytes)"
[ "$FAIL" -eq 0 ]
