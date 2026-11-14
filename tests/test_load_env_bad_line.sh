#!/usr/bin/env bash
# tests/test_load_env_bad_line.sh — every _load_env copy keeps loading a .env
# past one malformed assignment, and its warning names the key it lost.
#
# Usage: tests/test_load_env_bad_line.sh
#
# Why: the extractor regex tolerates spaces around the equals sign, so a line
# like `FOO = bar` becomes a *key* (FOO) while the shell reads it as a command
# named FOO, which fails. Sourcing the whole file still succeeds when the last
# line assigns something, so the value capture dies on the unset key instead —
# and the failure branch did `return 0`, abandoning every later line of the
# file. One typo therefore silently dropped the rest of a user's .env, and the
# warning blamed the whole file rather than the one bad line.
#
# Fix under test: the failure branch warns about the key (`could not read FOO
# from <file>`) and `continue`s, so later lines still load. All seven copies of
# the loader carry the same body (bin/shellm, bin/llm, tools/persona,
# tools/headlong-init, both bridges, thinkers/_lib/common.sh), so the test
# extracts each one and runs it under the strictest host's option state
# (bin/shellm's set -euo pipefail), which is where the old shape lost the most.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

COPIES=(
    "bin/shellm:_shellm_load_env"
    "bin/llm:_llm_load_env"
    "tools/persona:_load_env"
    "tools/headlong-init:_load_env"
    "tools/headlong-slack-bridge:_load_env"
    "tools/headlong-telegram-bridge:_load_env"
    "thinkers/_lib/common.sh:_load_env_defaults"
)

# run_one <file> <fn> <envfile> [PRESET=v ...]
# Runs the extracted copy in a subshell under set -euo pipefail, prints
# `rc=<n>` then the loaded GOOD*/TOKEN values, and leaves stderr in $WORK/err.
run_one() {
    local file="$1" fn="$2" envfile="$3"; shift 3
    local extract
    extract="$WORK/$(printf '%s' "$file" | tr / -).fn"
    sed -n "/^${fn}() {/,/^}/p" "$REPO/$file" > "$extract"
    (
        set -euo pipefail
        # shellcheck disable=SC1090
        source "$extract"
        for kv in "$@"; do export "${kv%%=*}=${kv#*=}"; done
        "$fn" "$envfile" 2>"$WORK/err"
        printf 'rc=%s\n' "$?"
        printf '%s\n' "${GOOD1+GOOD1=$GOOD1}" "${GOOD2+GOOD2=$GOOD2}" \
                     "${TOKEN+TOKEN=$TOKEN}" | grep -v '^$' || true
    )
}

for spec in "${COPIES[@]}"; do
    file="${spec%%:*}"; fn="${spec##*:}"
    tag="${file##*/}"

    # --- one malformed line must not drop the rest of the file ---------------
    printf 'GOOD1=first\nFOO = bar\nGOOD2=second\n' > "$WORK/env"
    out=$(run_one "$file" "$fn" "$WORK/env")
    err=$(cat "$WORK/err")
    [[ "$out" == *"GOOD1=first"* ]] \
        && ok "$tag: key before the malformed line loads" \
        || bad "$tag: key before the malformed line loads" "$out"
    [[ "$out" == *"GOOD2=second"* ]] \
        && ok "$tag: key after the malformed line still loads" \
        || bad "$tag: key after the malformed line still loads" "$out"
    [[ "$out" != *"FOO="* ]] \
        && ok "$tag: the malformed key is not exported (not even empty)" \
        || bad "$tag: the malformed key is not exported" "$out"
    [[ "$err" == *"could not read FOO from"* ]] \
        && ok "$tag: the warning names the lost key and the file" \
        || bad "$tag: the warning names the lost key and the file" "$err"
    [[ "$out" == *"rc=0"* ]] \
        && ok "$tag: the loader still returns 0" \
        || bad "$tag: the loader still returns 0" "$out"

    # --- a file the shell cannot parse: warn, load nothing, keep going --------
    printf 'TOKEN="unterminated\n' > "$WORK/env"
    out=$(run_one "$file" "$fn" "$WORK/env"); err=$(cat "$WORK/err")
    [[ "$err" == *"could not read"* ]] \
        && ok "$tag: an unparseable file warns" \
        || bad "$tag: an unparseable file warns" "$err"
    [[ "$out" != *"TOKEN="* ]] \
        && ok "$tag: an unparseable file loads nothing" \
        || bad "$tag: an unparseable file loads nothing" "$out"
    [[ "$out" == *"rc=0"* ]] \
        && ok "$tag: an unparseable file does not fail the launch" \
        || bad "$tag: an unparseable file does not fail the launch" "$out"

    # --- stdout from a sourced command must stay out of values ---------------
    printf 'echo loading\nTOKEN=xoxb-clean\n' > "$WORK/env"
    out=$(run_one "$file" "$fn" "$WORK/env"); err=$(cat "$WORK/err")
    [[ "$out" == *"TOKEN=xoxb-clean"* ]] \
        && ok "$tag: a command's stdout stays out of the value" \
        || bad "$tag: a command's stdout stays out of the value" "$out"
    [[ -z "$err" ]] \
        && ok "$tag: a parseable file with a command warns about nothing" \
        || bad "$tag: a parseable file with a command warns about nothing" "$err"

    # --- the real environment wins over the file ------------------------------
    printf 'GOOD1=from-file\nGOOD2=from-file\n' > "$WORK/env"
    out=$(run_one "$file" "$fn" "$WORK/env" GOOD1=from-env)
    [[ "$out" == *"GOOD1=from-env"* ]] \
        && ok "$tag: an existing environment value is not overwritten" \
        || bad "$tag: an existing environment value is not overwritten" "$out"
    [[ "$out" == *"GOOD2=from-file"* ]] \
        && ok "$tag: unset keys still load from the file" \
        || bad "$tag: unset keys still load from the file" "$out"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
