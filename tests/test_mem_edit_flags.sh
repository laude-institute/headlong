#!/usr/bin/env bash
# tests/test_mem_edit_flags.sh — `mem edit` refuses a flag it does not know
# instead of clobbering the memory with it. Three times (2026-09-24 19:39Z,
# 2026-09-25 15:41Z, 2026-09-26 00:04Z) `mem edit <id> --apply <body>` stored
# a literal --apply as the whole body, exit 0, silent clobber of memory.
# Mirrors tests/test_mem_add_flags.sh (PR 134). No LLM calls, no docker.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export MEM_DIR="$WORK/mem"; mkdir -p "$MEM_DIR"

mem add --type todo --until 2026-09-30 "probe c5443cde body to protect" >/dev/null 2>&1
f=$(ls "$MEM_DIR"/*.md 2>/dev/null | head -1)
[[ -n "$f" ]] || { bad "setup: add failed"; printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1; }
id=$(sed -n 's/^id: //p' "$f")

# The three-times-earned clobber: a leading --apply must die, not write.
err=$(mem edit "$id" --apply "the real body" 2>&1 >/dev/null); rc=$?
[[ $rc -ne 0 ]] && ok "an unknown flag after edit fails (rc=$rc)" || bad "unknown flag fails"
printf '%s' "$err" | grep -q "unknown option '--apply'" && ok "the error names the flag" || bad "error names the flag" "$err"
grep -q 'probe c5443cde body to protect' "$f" && ok "the memory survived the refused edit" || bad "memory clobbered" "$(cat "$f")"

err=$(mem edit "$id" -h 2>&1 >/dev/null); rc=$?
[[ $rc -ne 0 ]] && ok "a single-dash flag fails (rc=$rc)" || bad "single-dash flag fails"
grep -q 'probe c5443cde body to protect' "$f" && ok "the memory survived -h" || bad "-h clobbered" "$(cat "$f")"

# The documented form still works, and fields ride through.
mem edit "$id" "edited body, still the same todo" >/dev/null 2>&1 && ok "the documented form still works" || bad "documented form"
f=$(grep -l "^id: $id$" "$MEM_DIR"/*.md 2>/dev/null | head -1)
grep -q '^edited body, still the same todo$' "$f" && ok "the new text is the body" || bad "body" "$(cat "$f")"
grep -q '^id: '"$id"'$' "$f" && ok "the id survives the edit" || bad "id lost" "$(cat "$f")"
grep -q '^until: 2026-09-30$' "$f" && ok "until rides through the edit" || bad "until lost" "$(cat "$f")"
grep -q '^type: todo$' "$f" && ok "type rides through the edit" || bad "type lost" "$(cat "$f")"

# stdin escape for text that genuinely starts with a dash.
mem edit "$id" >/dev/null 2>&1 <<'IN' && ok "stdin text still works" || bad "stdin"
--apply but the real body
IN
f=$(grep -l "^id: $id$" "$MEM_DIR"/*.md 2>/dev/null | head -1)
grep -q '^--apply but the real body$' "$f" && ok "the stdin body is verbatim" || bad "stdin body verbatim" "$(tail -3 "$f")"
grep -q '^id: '"$id"'$' "$f" && ok "the id survives the stdin edit" || bad "id lost on stdin" "$(cat "$f")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
