#!/usr/bin/env bash
# tests/test_mem_summary_clip.sh — a stored summary must never end inside a
# multi-byte UTF-8 character. Both summary write paths clipped at 80 bytes
# (`cut -c1-80` in mem add, `head -c 80` in mem edit) and on GNU coreutils
# under a UTF-8 locale both count bytes (probed 2026-09-30: cut -c output
# byte-identical to cut -b on two-byte and three-byte boundary cases), so a
# first line whose 80th byte fell inside an accented letter or an emoji
# stored an invalid-UTF-8 summary, which rides into every prompt and search
# call that carries it. No LLM calls, no docker.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export MEM_DIR="$WORK/mem"

E2=$(printf '\303\251')          # two-byte character
E3=$(printf '\342\202\254')       # three-byte character
E4=$(printf '\360\237\230\200')   # four-byte character
X78=$(printf 'x%.0s' {1..78})
X79=$(printf 'x%.0s' {1..79})
X80=$(printf 'x%.0s' {1..80})
X100=$(printf 'x%.0s' {1..100})

summary_of() { sed -n 's/^summary: //p' "$1" | head -1; }
bytes_of()  { printf '%s' "$1" | wc -c | tr -d ' '; }
hex_of()    { printf '%s' "$1" | od -An -tx1 | tr -s ' '; }
only_file() { ls "$MEM_DIR"/*.md 2>/dev/null | head -1; }

# add: the 80th byte falls inside each multi-byte width
for spec in "2:$E2" "3:$E3" "4:$E4"; do
    w=${spec%%:*}; ch=${spec#*:}
    rm -rf "$MEM_DIR"; mkdir -p "$MEM_DIR"
    mem add --type note "$X79$ch$ch tail after the clip" >/dev/null 2>&1
    f=$(only_file)
    [[ -n "$f" ]] || { bad "add (${w}-byte): nothing written"; continue; }
    s=$(summary_of "$f")
    if [[ "$s" == "$X79" ]]; then
        ok "add: ${w}-byte character split at byte 80 is clipped before"
    else
        bad "add: ${w}-byte character still split" "$(hex_of "$s")"
    fi
done

# add: a character completing exactly at byte 80 is kept whole
rm -rf "$MEM_DIR"; mkdir -p "$MEM_DIR"
mem add --type note "$X78$E2 and a tail" >/dev/null 2>&1
f=$(only_file); s=$(summary_of "$f")
[[ "$s" == "$X78$E2" ]] && ok "add: character completing at byte 80 kept whole" || bad "add: completion" "$(hex_of "$s")"
[[ $(bytes_of "$s") -eq 80 ]] && ok "add: completing summary is exactly 80 bytes" || bad "add: completion length" "$(bytes_of "$s")"

# add: ASCII clipping is byte-for-byte what it always was
rm -rf "$MEM_DIR"; mkdir -p "$MEM_DIR"
mem add --type note "$X100 tail" >/dev/null 2>&1
s=$(summary_of "$(only_file)")
[[ "$s" == "$X80" ]] && ok "add: ASCII summary clips at exactly 80 bytes" || bad "add: ASCII clip" "$(hex_of "$s")"

# add: in-limit multi-byte text passes through untouched
rm -rf "$MEM_DIR"; mkdir -p "$MEM_DIR"
mem add --type note "caf$E3 menu today" >/dev/null 2>&1
s=$(summary_of "$(only_file)")
[[ "$s" == "caf$E3 menu today" ]] && ok "add: in-limit multi-byte summary stored whole" || bad "add: in-limit" "$(hex_of "$s")"

# add: only the first line becomes the summary
rm -rf "$MEM_DIR"; mkdir -p "$MEM_DIR"
mem add --type note "$X79$E2$E2$E2
second line never reaches the summary" >/dev/null 2>&1
s=$(summary_of "$(only_file)")
[[ "$s" == "$X79" ]] && ok "add: multiline text keeps only the clipped first line" || bad "add: multiline" "$(hex_of "$s")"

# edit: the same boundary cases through the edit writer
rm -rf "$MEM_DIR"; mkdir -p "$MEM_DIR"
mem add --type note "seed memory for the edit cases" >/dev/null 2>&1
id=$(sed -n 's/^id: //p' "$(only_file)")
mem edit "$id" "$X79$E2$E2 tail after the clip" >/dev/null 2>&1
s=$(summary_of "$(only_file)")
[[ "$s" == "$X79" ]] && ok "edit: two-byte character split at byte 80 is clipped before" || bad "edit: split" "$(hex_of "$s")"
mem edit "$id" "$X78$E2 completing at eighty" >/dev/null 2>&1
s=$(summary_of "$(only_file)")
[[ "$s" == "$X78$E2" ]] && ok "edit: character completing at byte 80 kept whole" || bad "edit: completion" "$(hex_of "$s")"
mem edit "$id" "$X100 ascii long" >/dev/null 2>&1
s=$(summary_of "$(only_file)")
[[ "$s" == "$X80" ]] && ok "edit: ASCII summary clips at exactly 80 bytes" || bad "edit: ASCII clip" "$(hex_of "$s")"

# unit: the boundary classifier must agree under signed and unsigned char
# shells. printf '%d' "'<byte>" yields the byte as a C char: bash 5 is built
# with unsigned char, but macOS /bin/bash 3.2 sign-extends bytes >= 0x80 to
# negative, so the classifier's range tests against 128+ never fired, a lead
# byte split by the clip classified as ASCII and was kept, and the first CI
# run on this branch went red on macOS alone (6 passed, 5 failed, every
# failing case keeping the split lead byte). The helper normalizes negative
# values to 0-255 before comparing. This case emulates the signed
# convention inside the shell so the suite catches that class of
# regression on Linux as well; on a shell that already sign-extends, the
# emulation is a no-op pass-through.
helper=$(sed -n '/^clip_summary()/,/^)/p' "$REPO/bin/mem")
if [[ "$helper" == "clip_summary() ("* ]]; then
    sim="$WORK/sim_signed_char.sh"
    cat > "$sim" <<'EOS'
# Emulate the signed-char convention of bash 3.2 on macOS: quote-form
# values for bytes >= 0x80 come back negative. On a shell that already
# sign-extends, v >= 128 never holds and this is a pass-through.
printf() {
    if [[ "$1" == %d && "$2" == \'* ]]; then
        local v
        v=$(builtin printf '%d' "$2")
        if (( v >= 128 )); then v=$(( v - 256 )); fi
        builtin printf '%d\n' "$v"
        return 0
    fi
    builtin printf "$@"
}
EOS
    printf '%s\n' "$helper" >> "$sim"
    cat >> "$sim" <<'EOS'
r1=BAD; r2=BAD; r3=BAD; r4=BAD
a=$(clip_summary "$(printf 'x%.0s' {1..79})$(printf '\303\251')$(printf '\303\251') tail")
[[ "$a" == "$(printf 'x%.0s' {1..79})" ]] && r1=OK
a=$(clip_summary "$(printf 'x%.0s' {1..79})$(printf '\360\237\230\200') tail")
[[ "$a" == "$(printf 'x%.0s' {1..79})" ]] && r2=OK
a=$(clip_summary "$(printf 'x%.0s' {1..78})$(printf '\303\251') completing at eighty")
[[ "$a" == "$(printf 'x%.0s' {1..78})$(printf '\303\251')" ]] && r3=OK
a=$(clip_summary "$(printf 'x%.0s' {1..100}) ascii")
[[ ${#a} -eq 80 ]] && r4=OK
echo "$r1 $r2 $r3 $r4"
EOS
    out=$(bash "$sim" 2>&1)
    if [[ "$out" == "OK OK OK OK" ]]; then
        ok "unit: classifier clips cleanly under a signed-char shell"
    else
        bad "unit: signed-char shell (3.2 emulation)" "$out"
    fi
else
    bad "unit: clip_summary not found in bin/mem"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
