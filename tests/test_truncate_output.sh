#!/usr/bin/env bash
# Exercise the real truncate_output without running the launcher: the
# function is sliced out of bin/shellm and driven directly, so the test
# always runs the code that ships.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

awk '/^truncate_output\(\) \{$/,/^\}$/' "$REPO/bin/shellm" > "$WORK/fn"
[[ -s "$WORK/fn" ]] || { echo "FAIL: truncate_output not found in bin/shellm"; exit 1; }
grep -q "truncated" "$WORK/fn" || { echo "FAIL: slice lost the truncation marker"; exit 1; }

# The launcher's own default for the cap, then the real function, then a
# driver that reads the payload from stdin.
cat > "$WORK/prelude" <<'PRELUDE'
SHELLM_TRUNCATE="${SHELLM_TRUNCATE:-2000}"
PRELUDE
cat > "$WORK/driver" <<'DRIVER'
input=$(cat)
truncate_output "$input"
DRIVER
cat "$WORK/prelude" "$WORK/fn" "$WORK/driver" > "$WORK/run"

pass=0 fail=0
expect() {
    local name="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
        echo "FAIL: $name"
        echo "  got : $(printf '%s' "$got" | head -c 70 | tr '\n' '|')"
        echo "  want: $(printf '%s' "$want" | head -c 70 | tr '\n' '|')"
    fi
}

# Expected output for a payload of length L under effective cap E: the
# three-line shape the function documents, built independently of the
# ${input: -half} tail idiom the fix replaced, because that idiom returns
# the whole string when half is 0.
expected_for() {
    local payload="$1" E="$2"
    local L=${#payload}
    if (( L <= E )); then
        printf '%s\n' "$payload"
        return
    fi
    local half=$(( E / 2 ))
    local skipped=$(( L - E ))
    local tail=""
    (( half > 0 )) && tail="${payload: -half}"
    printf '%s\n%s\n%s\n' "${payload:0:$half}" "[... truncated $skipped chars ...]" "$tail"
}

run_case() {
    local name="$1" cap="$2" payload="$3" E="$4"
    local out
    if [[ "$cap" == "unset" ]]; then
        out=$(printf '%s' "$payload" | env -u SHELLM_TRUNCATE bash "$WORK/run" 2>&1)
    else
        out=$(printf '%s' "$payload" | SHELLM_TRUNCATE="$cap" bash "$WORK/run" 2>&1)
    fi
    expect "$name" "$out" "$(expected_for "$payload" "$E")"
}

M=$(printf '%*s' 3998 '' | tr ' ' M)
LONG="H${M}T"   # 4000 chars, distinct head and tail bytes

run_case "short input passes through" 2000 "hello world" 2000
run_case "unset cap uses the default" unset "$LONG" 2000
run_case "cap 0 falls back to the default" 0 "$LONG" 2000
run_case "negative cap falls back to the default" -5 "$LONG" 2000
run_case "non-numeric cap falls back to the default" abc "$LONG" 2000
run_case "cap 1 truncates rather than leak the whole input" 1 "$LONG" 1
run_case "odd cap keeps head and tail" 5 "$LONG" 5
run_case "input exactly -n is printed" unset "-n" 2000
run_case "input exactly -e is printed" unset "-e" 2000
run_case "newline inside a short input is preserved" 2000 "$(printf 'line1\nline2')" 2000

printf '%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
