#!/usr/bin/env bash
# test_mem_summary_derivation.sh — the frontmatter summary comes from the
# first non-blank line of the body, in both `mem add` and `mem edit`.
#
# Bug (live instances 2026-09-18 and 2026-09-28): both actions took head -1
# of the body, so a body opening with blank or whitespace-only lines — the
# common case when a heredoc's first line is empty — stored a blank
# `summary:`. `mem add` additionally slugified nothing and wrote a file with
# an empty summary; `mem edit` clobbered the stored summary of a live
# memory. A body with no non-blank line at all is now refused by both
# actions before anything is written. No LLM calls, no docker.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export MEM_DIR="$WORK/mem"; mkdir -p "$MEM_DIR"

# --- add: a blank-leading body takes the first non-blank line as summary ---
printf '\n\nFirst real line after two blanks\nSecond line\n' | mem add --type memory >/dev/null 2>&1 \
  && ok "add accepts a blank-leading body" || bad "add accepts a blank-leading body"
F=$(ls "$MEM_DIR"/*.md)
grep -q '^summary: First real line after two blanks$' "$F" \
  && ok "add summary is the first non-blank line" \
  || bad "add summary is the first non-blank line" "$(cat "$F")"

# --- add: a whitespace-only stdin body is refused, nothing written ---
before=$(ls "$MEM_DIR" | wc -l)
err=$(printf ' \n\t\n' | mem add --type note 2>&1 >/dev/null); rc=$?
[[ $rc -ne 0 ]] && ok "a whitespace-only add fails (rc=$rc)" || bad "whitespace-only add fails"
printf '%s' "$err" | grep -q "No text provided" \
  && ok "the add error names the problem" || bad "add error names the problem" "$err"
[[ $(ls "$MEM_DIR" | wc -l) -eq $before ]] \
  && ok "the refused add wrote nothing" || bad "refused add wrote nothing"

# --- add: a whitespace-only argument is refused too (used to store a blank summary) ---
err=$(mem add --type note "   " </dev/null 2>&1 >/dev/null); rc=$?
[[ $rc -ne 0 ]] && ok "a whitespace-only add argument fails (rc=$rc)" || bad "whitespace-only add argument fails"
[[ $(ls "$MEM_DIR" | wc -l) -eq $before ]] \
  && ok "the refused argument add wrote nothing" || bad "argument add wrote something"

# --- edit: blank-leading body takes the first non-blank line ---
id=$(sed -n 's/^id: //p' "$F")
printf '\n  \nEdited first real line\n' | mem edit "$id" >/dev/null 2>&1 \
  && ok "edit accepts a blank-leading body" || bad "edit accepts a blank-leading body"
F=$(ls "$MEM_DIR"/*.md)
grep -q '^summary: Edited first real line$' "$F" \
  && ok "edit summary is the first non-blank line" || bad "edit summary" "$(cat "$F")"
grep -q "^id: $id$" "$F" && ok "the id survives the edit" || bad "id lost"

# --- edit: a whitespace-only body is refused and the memory is untouched ---
before_sum=$(sed -n 's/^summary: //p' "$F" | head -1)
err=$(printf ' \n\t\n' | mem edit "$id" 2>&1 >/dev/null); rc=$?
[[ $rc -ne 0 ]] && ok "a whitespace-only edit fails (rc=$rc)" || bad "whitespace-only edit fails"
printf '%s' "$err" | grep -q "No text provided" \
  && ok "the edit error names the problem" || bad "edit error names the problem" "$err"
after_sum=$(sed -n 's/^summary: //p' "$F" | head -1)
[[ "$before_sum" == "$after_sum" ]] \
  && ok "the refused edit changed nothing" \
  || bad "refused edit changed something" "before=[$before_sum] after=[$after_sum]"
grep -q '^Edited first real line$' "$F" \
  && ok "the body survives the refused edit" || bad "body clobbered by the refused edit"

# --- exactly one summary line, never empty ---
n_all=$(grep -c '^summary:' "$F" || true)
n_empty=$(grep -c '^summary: *$' "$F" || true)
[[ "$n_all" -eq 1 && "$n_empty" -eq 0 ]] \
  && ok "one summary line, not empty" || bad "one summary line, not empty" "all=$n_all empty=$n_empty"

# --- plain bodies are unchanged (regression) ---
printf 'A plain body\n' | mem add --type note >/dev/null 2>&1
F=$(grep -l 'A plain body' "$MEM_DIR"/*.md | head -1)
grep -q '^summary: A plain body$' "$F" && ok "plain add unchanged" || bad "plain add unchanged"
id2=$(sed -n 's/^id: //p' "$F")
printf 'A plain edited body\n' | mem edit "$id2" >/dev/null 2>&1
F=$(grep -l "^id: $id2$" "$MEM_DIR"/*.md | head -1)
grep -q '^summary: A plain edited body$' "$F" && ok "plain edit unchanged" || bad "plain edit unchanged"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
