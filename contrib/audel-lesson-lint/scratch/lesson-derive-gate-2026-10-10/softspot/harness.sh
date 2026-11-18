#!/usr/bin/env bash
# softspot corpus: expected verdict per file name prefix (m-* refuse, a-* accept)
cd "$(dirname "$0")"
lint=../../../bin/lesson-overreach-lint
gap=0; pass=0; fail=0
for f in m-*.md a-*.md; do
  case "$f" in m-*) exp=refuse;; *) exp=accept;; esac
  if bash "$lint" "$f" >/dev/null 2>&1; then got=accept; else got=refuse; fi
  if [ "$got" = "$exp" ]; then
    printf 'ok   %-18s %s\n' "$f" "$exp"; pass=$((pass+1))
  else
    printf 'FAIL %-18s want=%s got=%s\n' "$f" "$exp" "$got"; fail=$((fail+1))
    [ "$exp" = refuse ] && gap=$((gap+1))
  fi
done
printf 'pass=%s fail=%s of-which-gap(mutant-accepted)=%s\n' "$pass" "$fail" "$gap"
