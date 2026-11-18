# overreach-lint particle pass (2026-10-11)

Residuals taken from the irrtail note: the particle list is lexical so "the
latch flung open" stayed refused, and hasmain keyed on the verb list plus an
ed suffix so an irregular phrasal main predicate after the relative ("the
reviewer notes kept rang out") dropped the bound.

Both were real. Fixture pair a-flungopen.md / a-keepphrasal-main.md refused
pre-fix and accept post.

Two fixes, one per path:
1. particle list widened with open|shut|root|online|ahead|apart.
2. hasmain now counts the same verb shapes the search uses (vb list, verb
   shape, and the verb-slot-word-plus-particle shape).

Controls held: m-adjopen (adjective before particle word), m-presentverb-nomain
(present relative, no main), m-shapenopast (present takes root),
m-tookroot-present, m-toolsnoun (tools as noun) all refuse. Accepts
a-broughtonline, a-flungbare, a-outdrove2, a-setinmotion, a-tookroot unchanged.

Same-set sweep over 441 tree fixtures: exactly 2 flips (the gap pair above),
zero other movement. Suite run-all.sh 17 corpora pass=333 fail=0.

Folded gate: 7 of 7 evidence lines re-derived and reach lint clean.

Pre-patch binary: scratch/lesson-derive-gate-2026-10-10/particle/lint.pre-particlefix
Lesson stored 2026-10-11-21-20-03_4d949f6d.

Residual named for the next pass: the particle list is still lexical, so a
multiword particle like "set in motion" is read through its first word only,
and irregular-past phrasal verbs outside the widened list stay unread.
