#!/usr/bin/env bash
# Source the real fence consumers; never execute model-provided test code.
# Both consumers must distinguish documentation/string contents from shell
# heredocs, and preserve literal fences inside genuine heredoc bodies.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

for fn in script_parses strip_markup_suffix normalize_toolcall_markup extract_code; do
    sed -n "/^$fn() {/,/^}/p" "$REPO/bin/shellm"
done > "$WORK/extract"
sed -n '/^_fs_buf=/,/^_emit_text() {/p' "$REPO/bin/llm" | sed '$d' > "$WORK/stream"
# shellcheck disable=SC1091
source "$WORK/extract"
# shellcheck disable=SC1091
source "$WORK/stream"

check() {
    local label="$1" code response actual line closed=0 premature=0
    code=$(cat)
    response=$(printf '```bash\n%s\n```\nTAIL_MUST_NOT_APPEAR\n' "$code")
    actual=$(extract_code "$response")
    if [[ "$actual" == "$code" ]]; then ok "$label extract"; else bad "$label extract"; fi
    _fs_buf="" _fs_in=0 _fs_hd=() _fs_bytes=0
    # Each case forks from the freshly sourced parent, so lexer state
    # cannot leak from an earlier case, even if the fix adds more globals.
    {
        printf '```bash\n%s\n' "$code"
    } > "$WORK/lines"
    while IFS= read -r line; do
        if _fs_line "$line"; then premature=1; fi
    done < "$WORK/lines"
    if _fs_line '```'; then closed=1; fi
    if [[ "$premature" -eq 0 && "$closed" -eq 1 ]]; then
        ok "$label stream"
    else
        bad "$label stream"
    fi
}
cases() {
# The subshell keeps the scanner's global state isolated between cases.
(check 'double quoted operator' <<'CASE'
printf '%s\n' "start << done"
CASE
)
(check 'single quoted operator' <<'CASE'
printf '%s\n' '<<FAKE'
CASE
)
(check 'comment operator' <<'CASE'
echo ok # use <<EOF in documentation
CASE
)
(check 'multiline single quote' <<'CASE'
python3 -c '
s = "<<EOF"
print(s)
'
CASE
)
(check 'multiline double quote' <<'CASE'
printf '%s\n' "first
<<FAKE
last"
CASE
)
(check 'escaped double quote' <<'CASE'
echo "escaped \" <<FAKE"
CASE
)
(check 'ANSI quoted escaped quote' <<'CASE'
echo $'escaped \' <<FAKE'
CASE
)
(check 'real heredoc control' <<'CASE'
cat <<'EOF'
```
EOF
CASE
)
(check 'real after quoted fake' <<'CASE'
printf '%s\n' '<<IGNORED'; cat <<REAL
```
REAL
CASE
)
(check 'fake opener in body' <<'CASE'
cat <<EOF
examples <<FAKE
```
EOF
CASE
)
(check 'queued heredocs' <<'CASE'
cat <<ONE <<TWO
one
ONE
```
TWO
CASE
)
(check 'hash within word' <<'CASE'
echo name#suffix; cat <<EOF
```
EOF
CASE
)
(check 'escaped hash' <<'CASE'
printf x\#y; cat <<EOF
```
EOF
CASE
)
(check 'arithmetic variable shift' <<'CASE'
echo $((1 << count))
CASE
)
(check 'here string control' <<'CASE'
cat <<< 'string'
CASE
)
(check 'heredoc inside quoted substitution' <<'CASE'
x="$(cat <<EOF
```
EOF
)"
CASE
)

}
cases > "$WORK/results"
cat "$WORK/results"
pass=$(grep -c '^ok   ' "$WORK/results" || true)
fail=$(grep -c '^FAIL ' "$WORK/results" || true)
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
