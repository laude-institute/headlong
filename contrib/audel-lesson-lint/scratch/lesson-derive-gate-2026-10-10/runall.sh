#!/usr/bin/env bash
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
L="$ROOT/bin/lesson-overreach-lint"
for dir in reachgap edge edge/labelbreak overreach/fix fold/fix fieldtest fieldtest2 fieldtest3 softspot; do
  d="$ROOT/scratch/lesson-derive-gate-2026-10-10/$dir"
  [ -d "$d" ] || continue
  for f in "$d"/*.md; do
    [ -f "$f" ] || continue
    if bash "$L" "$f" >/dev/null 2>&1; then rc=0; else rc=1; fi
    printf '%s %s\n' "$rc" "${f#$ROOT/scratch/lesson-derive-gate-2026-10-10/}"
  done
done
