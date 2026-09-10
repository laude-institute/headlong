#!/usr/bin/env bash
# tests/run-all.sh — run every tests/test_*.sh and summarize.
#
# Usage: tests/run-all.sh [pattern]
#   pattern   only run scripts whose name contains this substring
#             (e.g. `tests/run-all.sh recap`)
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

HERE="$(cd "$(dirname "$0")" && pwd)"
pattern="${1:-}"

pass=() fail=()
for t in "$HERE"/test_*.sh; do
    name=$(basename "$t")
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
printf 'passed: %d\n' "${#pass[@]}"
for p in "${pass[@]+"${pass[@]}"}"; do printf '  ok   %s\n' "$p"; done
printf 'failed: %d\n' "${#fail[@]}"
for f in "${fail[@]+"${fail[@]}"}"; do printf '  FAIL %s\n' "$f"; done

[[ "${#fail[@]}" -eq 0 ]]
