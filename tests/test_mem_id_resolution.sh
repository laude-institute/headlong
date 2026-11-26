#!/usr/bin/env bash
# tests/test_mem_id_resolution.sh — `mem show/forget/edit <id>` resolve a hex
# id against the id field of the filename (TS_<8hex>_<slug>) only. A query
# that is also valid hex ("dead", "cafe", "2026") must not match the start of
# another memory's slug: forget would delete the wrong memory, and a real id
# prefix would be refused as ambiguous. No LLM calls, no docker.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export MEM_DIR="$WORK/mem"; mkdir -p "$MEM_DIR"

put() { printf -- '---\nsummary: %s\n---\n%s\n' "$2" "$2" > "$MEM_DIR/$1.md"; }
TAXES=2026-11-26-10-00-00_a014ac15_deadline-for-taxes
OTHER=2026-11-26-10-00-01_dead1234_other-note
put "$TAXES" "deadline for taxes is april"

# The slug starts with hex: before the fix this resolved to TAXES and deleted it.
err=$(mem forget dead 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "forget with a slug-only hex match fails (rc=$rc)" || bad "slug-only match fails" "$err"
printf '%s' "$err" | grep -q "Memory not found: dead" && ok "the error says not found" || bad "not-found error" "$err"
[[ -f "$MEM_DIR/$TAXES.md" ]] && ok "the memory whose slug matched survives" || bad "slug-matched memory survives"
mem show dead >/dev/null 2>&1 && bad "show with a slug-only hex match fails" || ok "show with a slug-only hex match fails"

# A real id prefix must win, not be refused as ambiguous against a slug.
put "$OTHER" "another note"
out=$(mem show dead 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "a real id prefix resolves (rc=0)" || bad "real id prefix resolves" "$out"
printf '%s' "$out" | grep -q '^another note$' && ok "it resolves to the memory with that id" || bad "resolves to the id's memory" "$out"

# Id prefixes of 4 to 8 chars still resolve, and the full id too.
mem show a014 2>/dev/null | grep -q '^deadline for taxes is april$' && ok "a 4-char id prefix resolves" || bad "4-char prefix"
mem show a014ac15 2>/dev/null | grep -q '^deadline for taxes is april$' && ok "the full id resolves" || bad "full id"

# Two ids sharing a prefix are still ambiguous.
put 2026-11-26-10-00-02_dead5678_third-note "third note"
err=$(mem show dead 2>&1); rc=$?
[[ $rc -ne 0 ]] && printf '%s' "$err" | grep -q "Ambiguous: 'dead'" && ok "a prefix shared by two ids is ambiguous" || bad "shared prefix ambiguous" "$err"

# A legacy filename (TS_slug, no id) is reachable by exact name, never by a hex
# query that happens to match its slug.
LEGACY=2026-11-26-10-00-03_beef-stew-recipe
put "$LEGACY" "beef stew recipe"
mem show beef >/dev/null 2>&1 && bad "a legacy slug is not an id" || ok "a legacy slug is not an id"
mem show "$LEGACY" 2>/dev/null | grep -q '^beef stew recipe$' && ok "a legacy memory resolves by exact name" || bad "legacy exact name"

# A body with no letters or digits gets an empty slug (TS_<hex>_); its id
# still resolves.
EMPTY=2026-11-26-10-00-04_5e1627ec_
put "$EMPTY" "---"
mem show 5e16 2>/dev/null | grep -q '^---$' && ok "an empty-slug memory resolves by id" || bad "empty-slug id"

# The fixed forget deletes exactly the id it was given.
mem forget dead1234 >/dev/null 2>&1 && ok "forget by id succeeds" || bad "forget by id"
[[ ! -f "$MEM_DIR/$OTHER.md" && -f "$MEM_DIR/$TAXES.md" ]] && ok "forget removed only that memory" || bad "forget removed only that memory" "$(ls "$MEM_DIR")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
