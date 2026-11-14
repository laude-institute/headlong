#!/usr/bin/env bash
# Exercise the actual --bin install loop without Docker: docker is mocked.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Slice the real --bin install loop out of the launcher, from its comment
# marker through the loop's closing "done".
awk '
    /# Install --bin binaries/ { copying=1 }
    copying { print }
    copying && /^    done$/ { exit }
' "$REPO/bin/shellm" > "$WORK/body"
[[ -s "$WORK/body" ]] || { echo "FAIL: --bin install loop not found in bin/shellm"; exit 1; }
grep -q "docker cp" "$WORK/body" || { echo "FAIL: loop slice lost the copy step"; exit 1; }

mkdir -p "$WORK/src"
printf 'requested binary bytes\n' > "$WORK/src/mytool"
chmod +x "$WORK/src/mytool"
printf 'image shipped different bytes\n' > "$WORK/dest-collision"
cp "$WORK/src/mytool" "$WORK/dest-rerun"
chmod +x "$WORK/dest-collision" "$WORK/dest-rerun"

# Assemble the program by concatenation: a docker mock that stands in for
# the container (the guard's cat reads the mock destination file, test -x
# probes it, cp and chmod are recorded), the loop variables, then the real
# loop body wrapped in a function so its "local" statements are legal.
cat > "$WORK/prelude" <<'PRELUDE'
docker() {
    if [[ "$1" == cp ]]; then
        echo cp >> "$TRACE"
        return 0
    fi
    case "$*" in
        *" test -x "*)
            [[ -x "$DEST_FILE" ]] ;;
        *" cat "*)
            cat "$DEST_FILE" 2>/dev/null ;;
        *" chmod "*)
            echo chmod >> "$TRACE" ;;
        *)
            echo "unexpected docker call: $*" >&2
            return 1 ;;
    esac
}
_SHELLM_CONTAINER=mocked
_SHELLM_EXTRA_BINS=("$SRC_FILE")
the_loop() {
PRELUDE
{ cat "$WORK/prelude"; cat "$WORK/body"; printf '}\nthe_loop\n'; } > "$WORK/program"
bash -n "$WORK/program" || { echo "FAIL: assembled program does not parse"; exit 1; }

pass=0 fail=0
expect() {
    local what="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        echo "ok $what"; pass=$((pass+1))
    else
        echo "FAIL $what: got '$got' want '$want'"; fail=$((fail+1))
    fi
}

run_case() {
    local name="$1" dest="$2" want_cp="$3"
    : > "$WORK/trace"
    rc=0
    SRC_FILE="$WORK/src/mytool" DEST_FILE="$dest" TRACE="$WORK/trace" \
        bash "$WORK/program" >/dev/null 2>&1 || rc=$?
    expect "$name exits 0" "$rc" 0
    local cp_seen=no chmod_seen=no
    grep -q '^cp$' "$WORK/trace" && cp_seen=yes
    grep -q '^chmod$' "$WORK/trace" && chmod_seen=yes
    expect "$name copies the binary" "$cp_seen" "$want_cp"
    expect "$name chmods the binary" "$chmod_seen" "$want_cp"
}

run_case missing "$WORK/dest-missing" yes
run_case collision "$WORK/dest-collision" yes
run_case rerun "$WORK/dest-rerun" no

printf '%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
