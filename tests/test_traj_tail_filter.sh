#!/usr/bin/env bash
# tests/test_traj_tail_filter.sh — `traj tail -n N --filter F` returns the
# last N steps that match F, the way `traj tail -r` already does.
#
# Usage: tests/test_traj_tail_filter.sh
#
# Why: the single-file tail cut the file to its last N lines first and filtered
# what was left, so it returned only the matches among those N lines. On a
# trajectory ending "thought, message, action", `traj tail -n 2 --filter
# type=thought` printed nothing and exited 0, while `traj tail -r -n 2 --filter
# type=thought` printed the two newest thoughts. The harness relies on the -r
# meaning: _recent_stream (thinkers/_lib/common.sh) stamps each run's final in
# the wake prompt with `traj tail -n 400 --filter run_id=<id>` as the command
# that prints the run's steps, and every monolith run writes into the one root
# trajectory. For a run that ended more than 400 lines back, which the recent
# stream (read from the last 5000 lines) shows routinely, that command came
# back empty.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID \
    SHELLM_RUN_STEP_ID SHELLM_RAW_TAIL_LINES 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
is()  { # is LABEL EXPECTED ACTUAL
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi
}

command -v jq >/dev/null 2>&1 || { echo "FAIL jq not found"; exit 1; }

WORK=$(mktemp -d)
follower=""
cleanup() {
    [[ -z "$follower" ]] || kill -- "-$follower" 2>/dev/null || true
    cd / && rm -rf "$WORK"
}
trap cleanup EXIT

contents() { jq -r '.content // empty' | tr '\n' ' ' | sed 's/ $//'; }

export TRAJ_DIR="$WORK/trajectories"
mkdir -p "$TRAJ_DIR"
TRAJ_ID=$(traj new --slug root | head -1)
export TRAJ_ID
traj append --field type=thought --field content=T1 >/dev/null
traj append --field type=action  --field content=A1 >/dev/null
traj append --field type=thought --field content=T2 >/dev/null
traj append --field type=message --field content=M1 >/dev/null
traj append --field type=action  --field content=A2 >/dev/null
FILE=$(traj path)
[[ -f "$FILE" ]] || { echo "FAIL could not build the trajectory"; exit 1; }

# --- -n counts the steps that match, not the file's last lines ----------------
out=$(traj tail -n 2 --raw --filter type=thought); rc=$?
is "tail -n 2 --filter exits 0" "0" "$rc"
is "tail -n 2 --filter returns the two newest matches" "T1 T2" \
   "$(printf '%s\n' "$out" | contents)"
is "tail -n 1 --filter returns the newest match" "T2" \
   "$(traj tail -n 1 --raw --filter type=thought | contents)"
is "fewer matches than -n returns all of them" "T1 T2" \
   "$(traj tail -n 3 --raw --filter type=thought | contents)"
is "two --filter flags are AND-ed before the count" "T2" \
   "$(traj tail -n 1 --raw --filter type=thought --filter content=T2 | contents)"
is "comma values are OR-ed before the count" "T2 M1" \
   "$(traj tail -n 2 --raw --filter type=thought,message | contents)"
is "the formatted view counts the same way" "T1 T2" \
   "$(traj tail -n 2 --format --no-color --filter type=thought | awk '{print $NF}' | tr '\n' ' ' | sed 's/ $//')"

# --- the single-file tail agrees with -r and with cat --------------------------
is "tail and tail -r agree on a one-file tree" \
   "$(traj tail -r -n 2 --raw --filter type=thought | contents)" \
   "$(traj tail -n 2 --raw --filter type=thought | contents)"
is "tail -n N --filter F is the last N lines of cat --filter F" \
   "$(traj cat --raw --filter type=thought,action | tail -n 3)" \
   "$(traj tail -n 3 --raw --filter type=thought,action)"

# --- without a filter, tail is untouched ---------------------------------------
is "unfiltered tail -n 2 is the file's last two lines, byte for byte" \
   "$(tail -n 2 "$FILE")" "$(traj tail -n 2 --raw)"

# --- -f replays the same steps before it follows -------------------------------
# Job control gives the follower a process group of its own, so the kill takes
# its tail -F pipeline down with it.
set -m
traj tail -f -n 2 --raw --filter type=thought > "$WORK/follow.out" 2>/dev/null &
follower=$!
set +m
for _ in $(seq 1 100); do
    [[ "$(grep -c . "$WORK/follow.out" 2>/dev/null)" -ge 2 ]] && break
    sleep 0.1
done
kill -- "-$follower" 2>/dev/null || true
wait "$follower" 2>/dev/null || true
follower=""
is "tail -f -n 2 --filter replays the two newest matches" "T1 T2" \
   "$(contents < "$WORK/follow.out")"

# --- the run details command the wake prompt hands the mind ---------------------
# One root trajectory, as the monolith writes it: an earlier run, then a later
# run long enough to push the earlier one out of the file's last 400 lines.
# The command under test is the one _recent_stream stamps on the earlier
# run's final, run as printed.
ID="$WORK/ident"
RTRAJ="cafe0000-0000-0000-0000-0000000000ef"
mkdir -p "$ID/trajectories/$RTRAJ"
RFILE="$ID/trajectories/$RTRAJ/trajectory.jsonl"
step() { # step <id> <type> <run_id> <content>
    printf '{"step_id":"%s","type":"%s","run_id":"%s","content":"%s","ts":"%s"}\n' \
        "$1" "$2" "$3" "$4" "2026-09-02T12:00:00.000Z" >> "$RFILE"
}
printf '{"step_id":"%s","type":"trajectory","ts":"2026-09-02T11:00:00.000Z"}\n' "$RTRAJ" > "$RFILE"
step a1 reasoning    run-a a-one
step a2 shell-output run-a a-two
step af final        run-a a-done
for i in $(seq 1 450); do step "b$i" reasoning run-b "b-$i"; done
step bf final        run-b b-done
export TRAJ_DIR="$ID/trajectories" TRAJ_ID="$RTRAJ"
details=$(
    export IDENTITY_NAME=ada IDENTITY_DIR="$ID" MEM_DIR="$ID/memories"
    # shellcheck disable=SC1091
    source "$REPO/thinkers/_lib/common.sh"
    _recent_stream 20 | jq -r 'select(.step_id == "af") | .details // empty'
)
case "$details" in
    "traj tail "*"--filter run_id=run-a")
        ok "the earlier run's final carries a traj tail --filter command" ;;
    *)  bad "the earlier run's final carries a traj tail --filter command" "got [$details]" ;;
esac
cmd=(traj tail -n 400 --filter run_id=run-a)
[[ -n "$details" ]] && read -r -a cmd <<< "$details"
is "that command prints the whole earlier run" "a-one a-two a-done" \
   "$("${cmd[@]}" --raw | contents)"
is "-n still bounds a run longer than N, keeping its newest steps" "b-449 b-450 b-done" \
   "$(traj tail -n 3 --raw --filter run_id=run-b | contents)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
