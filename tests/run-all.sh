#!/usr/bin/env bash
# tests/run-all.sh — run every tests/test_*.sh and summarize.
#
# Usage: tests/run-all.sh [pattern]
#   pattern   only run scripts whose name contains this substring
#             (e.g. `tests/run-all.sh recap`)
#
# TEST_SHARD=i/n runs only the i-th of n slices of the suite (1-based), for
# CI jobs that split the suite across runners. The n slices are disjoint and
# together cover every script. tests/test_run_all_shards.sh checks that.
#
# Each test script is self-contained and prints its own ok/FAIL lines; this
# runner just executes them in turn, records the exit code and wall time,
# and exits non-zero if any script failed. CI calls this; locally you can
# still run a single script directly.

set -uo pipefail

# Hermetic by design (laude-institute/headlong#117): running the suite from inside
# an activated identity must not leak its identity/trajectory env into the tests.
# tools/identity re-roots to the caller's live .identities when IDENTITY_NAME and
# IDENTITY_DIR point at an active identity, so `identity new` inside a test would write
# there instead of the test's own temp app dir. Every test unsets or exports its own
# values, so the suite itself needs none of these.
unset IDENTITY_NAME IDENTITY_DIR MEM_DIR SKILLS_DIR SKILLS_KERNEL_DIR TRAJ_ID TRAJ_DIR ROOT_TRAJ_ID
# A nested-run marker would make bin/shellm refuse the tests' top-level
# --resume calls (the resume guard), so clear it too: the suite must pass
# the same way inside a shellm run as outside one.
unset SHELLM_RUN_STEP_ID

HERE="$(cd "$(dirname "$0")" && pwd)"
pattern="${1:-}"

# Slices are balanced by wall time, not by count: each script goes to the
# slice with the least time so far, slowest scripts first. SLOW lists the
# scripts that take 12 s or more with their macOS CI seconds (run
# 37511119972, 2026-10-06); every other script counts as 4 s. These numbers
# only affect balance. A stale or missing entry never drops a script.
SLOW="test_contrib_opencode.sh:263 test_thinkers_pending.sh:66
test_thinkers_stuck_step.sh:44 test_inactivity_beacon.sh:40
test_monolith_backoff.sh:39 test_thinkers_wake_at.sh:37
test_responder_deferral.sh:35 test_responder_reply_guard.sh:26
test_thinkers_trajectory_swap.sh:23 test_output_size_watchdog.sh:18
test_llm_adapter.sh:17 test_rollup_namer_limits.sh:17
test_traj_redaction.sh:17 test_monolith_request_model.sh:16
test_thinkers_drain.sh:13 test_mem_search_adapter_bound.sh:12"

shard_i=1 shard_n=1
if [[ -n "${TEST_SHARD:-}" ]]; then
    if [[ "$TEST_SHARD" =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]] && (( BASH_REMATCH[1] <= BASH_REMATCH[2] )); then
        shard_i=${BASH_REMATCH[1]} shard_n=${BASH_REMATCH[2]}
    else
        echo "run-all.sh: TEST_SHARD must be i/n with 1 <= i <= n, got '$TEST_SHARD'" >&2
        exit 2
    fi
fi

# Print the names of the scripts in this slice, one per line.
shard_members() {
    local ordered=() load=() entry name w i min t
    for entry in $SLOW; do
        [[ -f "$HERE/${entry%%:*}" ]] && ordered+=("$entry")
    done
    for t in "$HERE"/test_*.sh; do
        name=$(basename "$t")
        [[ " $SLOW" == *[[:space:]]"$name":* ]] || ordered+=("$name:4")
    done
    for (( i = 0; i < shard_n; i++ )); do load[i]=0; done
    for entry in "${ordered[@]+"${ordered[@]}"}"; do
        name=${entry%%:*} w=${entry##*:} min=0
        for (( i = 1; i < shard_n; i++ )); do
            (( load[i] < load[min] )) && min=$i
        done
        load[min]=$(( load[min] + w ))
        (( min + 1 == shard_i )) && printf '%s\n' "$name"
    done
    return 0
}
mine=$'\n'$(shard_members)$'\n'

pass=() fail=()
for t in "$HERE"/test_*.sh; do
    name=$(basename "$t")
    [[ "$mine" == *$'\n'"$name"$'\n'* ]] || continue
    [[ -z "$pattern" || "$name" == *"$pattern"* ]] || continue
    printf '\n===== %s =====\n' "$name"
    start=$SECONDS
    if bash "$t"; then
        pass+=("$name ($((SECONDS - start))s)")
    else
        fail+=("$name ($((SECONDS - start))s)")
    fi
done

printf '\n===== summary =====\n'
[[ "$shard_n" -eq 1 ]] || printf 'slice: %d of %d\n' "$shard_i" "$shard_n"
printf 'passed: %d\n' "${#pass[@]}"
for p in "${pass[@]+"${pass[@]}"}"; do printf '  ok   %s\n' "$p"; done
printf 'failed: %d\n' "${#fail[@]}"
for f in "${fail[@]+"${fail[@]}"}"; do printf '  FAIL %s\n' "$f"; done

[[ "${#fail[@]}" -eq 0 ]]
