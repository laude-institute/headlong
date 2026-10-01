#!/usr/bin/env bash
# tests/test_mem_summary_epipe.sh — a large body must not kill `mem add` or
# `mem edit` at the summary line. Both extracted the first line through
# `printf '%s' "$text" | head -1 | ...` under `set -euo pipefail`: head -1
# exits as soon as it has its line, the printf producer can still be holding
# megabytes of unwritten body, and its subshell takes SIGPIPE; pipefail
# makes the pipeline nonzero and set -e kills the command before any file
# write. Observed live 2026-10-01 11:40Z (mem edit: 28.6KB body, 1.6KB first
# line, EPIPE at the summary line, store untouched, retry landed). At that
# size the race fires only sometimes; this test forces it with two 1MB lines
# so the producer always has a megabyte left when the reader exits, which
# makes the failure deterministic on main and the fix provable. No LLM
# calls, no docker.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export MEM_DIR="$WORK/mem"; mkdir -p "$MEM_DIR"

line_a=$(head -c 1048576 /dev/zero | tr '\0' 'a')
line_b=$(head -c 1048576 /dev/zero | tr '\0' 'b')
printf '%s\n%s\n' "$line_a" "$line_b" > "$WORK/big.md"
bytes=$(wc -c < "$WORK/big.md")

# Tail checks read the last 17 bytes (16 b's plus the file's final
# newline) and compare against 16 b's: $() strips the trailing newline,
# so the expectation is the stripped form.
# --- mem add: the whole body lands in the store, or the failure is named ---
mem add "seed memory for the epipe test" >/dev/null 2>&1 || { bad "setup add"; printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1; }
count=$(ls -1 "$MEM_DIR"/*.md | wc -l)
seed=$(grep -l "seed memory for the epipe test" "$MEM_DIR"/*.md | head -1)
id=$(sed -n 's/^id: //p' "$seed")

err=$(mem add < "$WORK/big.md" 2>&1 >/dev/null); rc=$?
[[ $rc -eq 0 ]] && ok "mem add stores a 2MB body (rc=0)" || bad "mem add stores a 2MB body" "rc=$rc err=${err:0:120}"
n=$(ls -1 "$MEM_DIR"/*.md | wc -l)
[[ $n -eq 2 ]] && ok "the big memory exists as a file" || bad "the big memory file is missing" "count=$n"
bigf=$(grep -lF "summary: ${line_a:0:80}" "$MEM_DIR"/*.md 2>/dev/null | head -1)
[[ -n "$bigf" ]] && ok "the big add carries a truncated summary" || bad "big add summary"
[[ -n "${bigf:-}" ]] && sz=$(wc -c < "$bigf") || sz=0
[[ "$sz" -ge "$bytes" ]] && ok "the big add body is whole ($sz bytes)" || bad "big add body truncated" "size=$sz want>=$bytes"
tail2=$(tail -c 17 "$bigf")
[[ "$tail2" == "${line_b:0:16}" ]] && ok "the big add body reaches the second line" || bad "big add body ends early" "tail=$tail2"

# --- mem edit: same pipeline, and the write is where a failure would hurt ---
err=$(mem edit "$id" < "$WORK/big.md" 2>&1 >/dev/null); rc=$?
[[ $rc -eq 0 ]] && ok "mem edit replaces the body with a 2MB one (rc=0)" || bad "mem edit with a 2MB body" "rc=$rc err=${err:0:120}"
ef=$(grep -l "^id: $id$" "$MEM_DIR"/*.md 2>/dev/null | head -1)
[[ -n "$ef" ]] && ok "the edited memory is findable by id" || bad "edited memory lost"
[[ -n "${ef:-}" ]] && sz=$(wc -c < "$ef") || sz=0
[[ "$sz" -ge "$bytes" ]] && ok "the edited body is whole ($sz bytes)" || bad "edited body truncated" "size=$sz want>=$bytes"
tail2=$(tail -c 17 "$ef")
[[ "$tail2" == "${line_b:0:16}" ]] && ok "the edited body reaches the second line" || bad "edited body ends early" "tail=$tail2"
grep -q '^type: memory$' "$ef" && ok "type rides through the big edit" || bad "type lost"
s=$(sed -n 's/^summary: //p' "$ef" | head -1)
[[ "${#s}" -le 80 && "$s" == a* ]] && ok "the edited summary is the first line, truncated" || bad "edited summary" "len=${#s}"

# --- small bodies still behave: the fix must not break the common path ---
err=$(mem edit "$id" "small body again" 2>&1 >/dev/null); rc=$?
[[ $rc -eq 0 ]] && ok "a small edit still works" || bad "small edit" "rc=$rc err=${err:0:120}"
ef=$(grep -l "^id: $id$" "$MEM_DIR"/*.md 2>/dev/null | head -1)
grep -q '^small body again$' "$ef" && ok "the small body is stored verbatim" || bad "small body stored"
err=$(mem add "second small memory" 2>&1 >/dev/null); rc=$?
[[ $rc -eq 0 ]] && ok "a small add still works" || bad "small add" "rc=$rc"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]] && exit 0 || exit 1
