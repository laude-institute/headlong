#!/usr/bin/env bash
set -u
B="$(cd "$(dirname "$0")/.." && pwd)"
set -- "$B/adjudicate/dummy.md"
[ -f "$1" ] || printf 'Lesson: dummy fixture for sourcing the defs.\n' > "$1"
. "$B/adjudicate/lint-defs.sh"
yn() { if eval "$2" >/dev/null 2>&1; then echo "$1: yes"; else echo "$1: no"; fi; }
echo "-- M1 modifier-vs-predicate (m-adjkept / m-adjgiven control):"
yn "  domain_self(all kept records failed)  [want: not name]" 'domain_self "all kept records failed"'
yn "  coref_ok(all kept records failed)     [want: judged=1]" 'coref_ok "all kept records failed"'
yn "  domain_self(all given fixtures failed)[want: names=0, green ctl]" 'domain_self "all given fixtures failed"'
echo "-- M1p harness-ss-plural (a-relcl-produced):"
yn "  relclause_ok(both fixtures the harness produced were refused) [want: yes]" 'relclause_ok "both fixtures the harness produced were refused"'
echo "-- M2 bothre detection:"
yn "  hits_of(both corpora failed) nonempty [want: yes]" '[ -n "$(hits_of "both corpora failed")" ]'
yn "  hits_of(both eager green fresh keen cohorts failed) nonempty [want: yes]" '[ -n "$(hits_of "both eager green fresh keen cohorts failed")" ]'
echo "-- M3 wrong-head relative (m-objrel):"
yn "  relclause_ok(all runs failed the checks the log read) [want: no]" 'relclause_ok "all runs failed the checks the log read"'
yn "  rcbre on clause" 'printf "%s\n" "all runs failed the checks the log read" | grep -qiE "$rcbre"'
echo "-- M4 possessive subject (a-rcdet-poss):"
yn "  relclause_ok(both soft spots my check flagged broke through) [want: yes]" 'relclause_ok "both soft spots my check flagged broke through"'
echo "-- M5 shared-VP count (a1):"
yn "  hits_of(re-ran all pass) nonempty" '[ -n "$(hits_of "re-ran all pass")" ]'
