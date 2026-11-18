#!/usr/bin/env bash
set -u
B="$(cd "$(dirname "$0")/.." && pwd)"
set -- "$B/adjudicate/dummy.md"
. "$B/adjudicate/lint-defs.sh"
yn() { if eval "$2" >/dev/null 2>&1; then echo "$1: yes"; else echo "$1: no"; fi; }
echo "-- M1 irregular-participle modifier:"
yn "  domain_self(all built machines failed)  [want not-name, now?]" 'domain_self "all built machines failed"'
yn "  coref_ok(all built machines failed)     [want corefer=0, now?]" 'coref_ok "all built machines failed"'
yn "  domain_self(all given fixtures failed)  [ctl names]" 'domain_self "all given fixtures failed"'
echo "-- M4 s-final singular subject:"
yn "  relcl(the harness produced)  [want yes, now no]" 'relclause_ok "both fixtures the harness produced were refused"'
yn "  relcl(the thing produced)    [ctl]" 'relclause_ok "both fixtures the thing produced were refused"'
echo "-- M2 bothre detection:"
yn "  hits_of(both corpora failed) nonempty   [want yes, now no]" '[ -n "$(hits_of "both corpora failed")" ]'
yn "  hits_of(both sessions failed) nonempty  [ctl]" '[ -n "$(hits_of "both sessions failed")" ]'
yn "  hits_of(both eager green fresh keen cohorts failed) nonempty [want yes, now no]" '[ -n "$(hits_of "both eager green fresh keen cohorts failed")" ]'
yn "  hits_of(both green cohorts failed) nonempty [ctl]" '[ -n "$(hits_of "both green cohorts failed")" ]'
echo "-- M3 false relative bound:"
yn "  relcl(all runs failed the checks the log read) [want no, now yes]" 'relclause_ok "all runs failed the checks the log read"'
echo "-- M5 determiner eaten by stop list:"
yn "  relcl(both soft spots my check flagged)  [want yes, now no]" 'relclause_ok "both soft spots my check flagged broke through"'
yn "  relcl(both soft spots the check flagged) [ctl]" 'relclause_ok "both soft spots the check flagged broke through"'
echo "-- M6 shared-VP continuation:"
yn "  coref_ok(re-ran all pass) [want corefer=0, now 1]" 'coref_ok "re-ran all pass"'
yn "  bound_in(the 3 fixtures I built) [sibbound]" 'bound_in "the 3 fixtures I built"'
yn "  hits_of(re-ran all pass) nonempty" '[ -n "$(hits_of "re-ran all pass")" ]'
