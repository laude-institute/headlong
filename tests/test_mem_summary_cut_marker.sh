#!/usr/bin/env bash
# test_mem_summary_cut_marker.sh — a first body line longer than 80 chars
# is clipped in the stored `summary:` (by design, for display), but the
# clip must be marked: the dropped character count plus a route to the
# whole line. A silently cut summary lets every later list/search row
# read as if the memory itself ended mid-word.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export MEM_DIR="$WORK/mem"; mkdir -p "$MEM_DIR"

LONG="This first line runs well past eighty characters so the stored summary cannot hold it whole and something has to be dropped at the cut"
SHORT="A short first line that fits whole"

# --- add: long first line is marked ---
printf '%s\nsecond line\n' "$LONG" | mem add --type memory >/dev/null 2>&1 \
  && ok "add accepts a long first line" || bad "add accepts a long first line"
F=$(ls "$MEM_DIR"/*.md | head -1)
SUM=$(sed -n 's/^summary: //p' "$F" | head -1)
if [[ "$SUM" == "$(printf '%s' "$LONG" | cut -c1-80)"*chars*route* ]]; then
  ok "add summary marks the dropped count and a route"
else
  bad "add summary marks the cut" "summary: $SUM"
fi

# --- add: short first line stays clean, no marker ---
printf '%s\nsecond\n' "$SHORT" | mem add --type note >/dev/null 2>&1
F2=$(ls -t "$MEM_DIR"/*.md | head -1)
SUM2=$(sed -n 's/^summary: //p' "$F2" | head -1)
[[ "$SUM2" == "$SHORT" ]] && ok "short summary carries no marker" \
  || bad "short summary carries no marker" "summary: $SUM2"

# --- edit: a long replacement body marks the cut too ---
id=$(sed -n 's/^id: //p' "$F")
printf '%s\nedited body\n' "$LONG" | mem edit "$id" >/dev/null 2>&1
SUME=$(sed -n 's/^summary: //p' "$F" | head -1)
if [[ "$SUME" == "$(printf '%s' "$LONG" | cut -c1-80)"*chars*route* ]]; then
  ok "edit summary marks the dropped count and a route"
else
  bad "edit summary marks the cut" "summary: $SUME"
fi

[[ $fail -eq 0 ]] && exit 0 || exit 1
