#!/usr/bin/env bash
set -u
W="$1"; G="$2"; D="$3"
pass=0; fail=0
chk() {
  name="$1"; want="$2"; fix="$3"
  out=$("$G" "$fix" 2>&1); got=$?
  if [ "$got" = "$want" ]; then
    printf 'ok   %s (rc=%s)\n' "$name" "$got"; pass=$((pass+1))
  else
    printf 'FAIL %s want rc=%s got rc=%s\n' "$name" "$want" "$got"
    printf '%s\n' "$out" | sed 's/^/     /'
    fail=$((fail+1))
  fi
}
echo "=== reach fixtures through the single gate ==="
for f in "$W"/fix/accept-*.md; do chk "accept-$(basename "$f" .md)" 0 "$f"; done
for f in "$W"/fix/refuse-*.md; do chk "refuse-$(basename "$f" .md)" 1 "$f"; done
echo "=== ordering: evidence refusal must win over reach ==="
chk "order-bad-both" 1 "$W/fix/order-bad-both.md"
echo "=== regression: recorded deepen verdicts ==="
while read -r fpath want; do
  chk "regress-$(basename "$fpath" .md)" "$want" "$fpath"
done < "$W/recorded.txt"
echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
