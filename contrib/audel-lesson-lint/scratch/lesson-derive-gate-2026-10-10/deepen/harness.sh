#!/usr/bin/env bash
set -u
D="$1"; G="$2"; OUT="$3"
: > "$OUT"
run() {
  f="$1"
  rc=0
  out=$("$G" "$D/$f.md" 2>&1) || rc=$?
  printf '%-12s rc=%s | %s\n' "$f" "$rc" "$(printf '%s' "$out" | tr '\n' '~')" >> "$OUT"
}
for f in d1 d2 d3 d4 d5 d6 d7 d8 d9 d10 d11 d12 d13 d14 d15; do run "deepen/$f"; done
for f in t1 t2 t3 t4 t5 t6 t7 t8; do run "$f"; done
