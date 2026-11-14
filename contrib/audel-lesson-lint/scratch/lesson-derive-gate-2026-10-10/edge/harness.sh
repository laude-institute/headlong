#!/usr/bin/env bash
set -u
E="$(cd "$(dirname "$0")" && pwd)"
L="$E/../../../bin/lesson-overreach-lint"
pass=0; fail=0; gaps=0; fp=0
while read -r want name; do
  out=$("$L" "$E/$name.md" 2>&1); got=$?
  if [ "$got" = "$want" ]; then
    printf 'ok   %-18s want=%s got=%s\n' "$name" "$want" "$got"; pass=$((pass+1))
  elif [ "$want" = 1 ]; then
    printf 'GAP  %-18s want=refuse got=accept: %s\n' "$name" "$(head -1 "$E/$name.md")"; gaps=$((gaps+1))
  else
    printf 'FP   %-18s want=accept got=refuse rc=%s\n' "$name" "$got"
    printf '%s\n' "$out" | head -2 | sed 's/^/       /'; fp=$((fp+1))
  fi
done < "$E/exp.txt"
echo "---"
echo "pass=$pass gaps=$gaps fp=$fp total=$((pass+gaps+fp))"
