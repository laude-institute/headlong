#!/usr/bin/env bash
set -u
E="$(cd "$(dirname "$0")" && pwd)"
w() { printf '%s\n' "$2" > "$E/$1.md"; }
# REFUSE-expected: unbounded universals, including forms outside the current
# quantifier word list (pre-registered as REFUSE; an accept is a gap).
w r-never-ever     'never once did the link between rule and interactions break'
w r-always-fact    'the gate always passes the control'
w r-upper          'the gate ALWAYS passes the control'
w r-nocircumstance 'under no circumstances should a lesson skip the gate'
w r-innocase       'in no case did the fix fail'
w r-nomatterwhat   'the gate holds no matter what the draft contains'
w r-alltimes       'at all times the reach lint runs first'
w r-invariably     'the re-derivation gate is invariably right'
w r-withoutfail    'the harness passes without fail'
w r-nolesson       'no lesson may skip the gate'
w r-eachandevery   'each and every check must run'
w r-everyrespect   'the fix holds in every respect'
w r-acrossboard    'the fix holds across the board'
w r-twosent        'in the 3 cases i checked the gate refused, and the fix always holds'
w r-normshield     'rule: never trust memory over the extract
the gate is always right'
# PASS-expected: bounded claims and non-claims, false-positive probes.
w p-count-all      'the 35 fixtures in the fold suite all pass'
w p-count-all-pre  'all 10 mutants were refused in the run'
w p-count-all-post 'in the 3 checks i ran the bad drafts all refused'
w p-install        'install the lint and run it on the draft'
w p-recall         'recall that the check ran clean'
w p-balloon        'the balloon test stayed clean'
w p-bounded        'in the 3 checks i ran the gate refused the bad draft'
w p-norm           'habit: never store a lesson that failed the gate'
w p-calls          'the calls came back clean'
w p-evid-quant     'evidence: contains /tmp/edge-nonexistent the fix always holds'
printf '%s\r\n' 'in the 2 windows i checked, nothing moved' > "$E/p-crlf.md"
printf '%s' 'the fix always holds' > "$E/r-nonewline.md"
