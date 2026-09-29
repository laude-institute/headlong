#!/usr/bin/env bash
# test_mem_flag_summary_warning.sh — a body whose first line opens with a
# command-flag-shaped word stores that line as the summary, with a warning
# on stderr. Deliberate dash text stores the same way it always did.
#
# Gap (live instances 2026-09-28, two of the five defects a full store sweep
# found): the stdin path exists so text that starts with a dash can be
# stored, and it checks nothing, so a piped add or edit whose text opens
# with a leftover command flag stores the flag line as the summary, and the
# flag reaches the slug and the file name. A blanket refusal would break the
# pipe path's purpose, so the fix warns on stderr and stores anyway. The
# check does not reject or rewrite the text. No LLM calls, no docker.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export MEM_DIR="$WORK/mem"; mkdir -p "$MEM_DIR"

# --- add: a flag-leading piped body stores, and warns on stderr ---
out=$(printf -- '--until 2026-10-05\nThe real body\n' | mem add --type note 2>"$WORK/err"); rc=$?
[[ $rc -eq 0 ]] && ok "a flag-leading piped add stores (rc=$rc)" || bad "flag-leading add stores" "rc=$rc"
grep -q "looks like a command flag (--until)" "$WORK/err" \
  && ok "the add warns on stderr" || bad "add warns on stderr" "$(cat "$WORK/err")"
F=$(ls "$MEM_DIR"/*.md)
grep -q '^summary: --until 2026-10-05$' "$F" \
  && ok "the flag line is stored as the summary" || bad "flag line as summary" "$(cat "$F")"
grep -q '^The real body$' "$F" && ok "the body is verbatim" || bad "body verbatim" "$(cat "$F")"
[[ "${F##*/}" == "$out.md" ]] && ok "stdout is still just the file name" || bad "stdout polluted" "$out"

# --- edit: the same shape on the edit path ---
id=$(sed -n 's/^id: //p' "$F")
out=$(printf -- '--slug leftover\nEdited body\n' | mem edit "$id" 2>"$WORK/err2"); rc=$?
[[ $rc -eq 0 ]] && ok "a flag-leading piped edit stores (rc=$rc)" || bad "flag-leading edit stores" "rc=$rc"
grep -q "looks like a command flag (--slug)" "$WORK/err2" \
  && ok "the edit warns on stderr" || bad "edit warns on stderr" "$(cat "$WORK/err2")"
F=$(grep -l "^id: $id$" "$MEM_DIR"/*.md)
grep -q '^summary: --slug leftover$' "$F" \
  && ok "the edit stores the flag line as the summary" || bad "edit flag summary" "$(cat "$F")"
grep -q '^Edited body$' "$F" && ok "the edited body is verbatim" || bad "edit body verbatim" "$(cat "$F")"
grep -q "^id: $id$" "$F" && ok "the id survives the warned edit" || bad "id lost"

# --- deliberate dash text stores and warns honestly (the tradeoff) ---
printf -- '-h the real body\n' | mem add --type note >"$WORK/out3" 2>"$WORK/err3"; rc=$?
[[ $rc -eq 0 ]] && ok "single-dash deliberate text still stores (rc=$rc)" || bad "deliberate dash stores" "rc=$rc"
grep -q "looks like a command flag (-h)" "$WORK/err3" \
  && ok "deliberate dash text gets the same warning" || bad "single-dash warn" "$(cat "$WORK/err3")"
F=$(grep -l '^-h the real body$' "$MEM_DIR"/*.md)
[[ -n "$F" ]] && ok "the deliberate dash body is verbatim" || bad "dash body verbatim"

# --- ordinary openers stay silent ---
: >"$WORK/err4"
printf 'A mid-dash word body\n' | mem add --type note >/dev/null 2>>"$WORK/err4"
printf -- '-5 degrees today\n' | mem add --type note >/dev/null 2>>"$WORK/err4"
F=$(grep -l '^-5 degrees today$' "$MEM_DIR"/*.md)
id4=$(sed -n 's/^id: //p' "$F")
printf 'A plain edited body\n' | mem edit "$id4" >/dev/null 2>>"$WORK/err4"
# mem edit always prints its own "Updated: ..." line to stderr, so silence
# here means no warning line, not an empty stream.
if grep -q "looks like a command flag" "$WORK/err4"; then
    bad "ordinary text warned" "$(grep "looks like a command flag" "$WORK/err4")"
else
    ok "mid-dash, negative and plain text stay silent"
fi

# Whitespace may hide an accidental flag; warning must not rewrite the body.
printf '\n   --until 2026-10-05\nIndented body\n' | mem add --type note >"$WORK/out5" 2>"$WORK/err5"
grep -q "looks like a command flag (--until)" "$WORK/err5" \
    && ok "a blank/indented opener warns" || bad "blank/indented flag missed"
F="$MEM_DIR/$(cat "$WORK/out5").md"
grep -q '^   --until 2026-10-05$' "$F" \
    && ok "indented body is unchanged" || bad "indented body rewritten"
id5=$(sed -n 's/^id: //p' "$F")
printf '\t--slug leftover\nIndented edit\n' | mem edit "$id5" >"$WORK/out6" 2>"$WORK/err6"
grep -q "looks like a command flag (--slug)" "$WORK/err6" \
    && ok "tab-indented edit warns" || bad "tab-indented edit missed"
# A normal Markdown list item is not a command flag.
printf -- '- a list item\n' | mem add --type note >/dev/null 2>"$WORK/err7"
if grep -q "looks like a command flag" "$WORK/err7"; then
    bad "ordinary list item warns"
else
    ok "ordinary list item stays silent"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
