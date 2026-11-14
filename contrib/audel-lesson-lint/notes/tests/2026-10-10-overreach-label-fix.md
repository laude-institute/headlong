# 2026-10-10 — overreach lint: mechanism-edge deepening and the label false positive

## What this covers
The third deepening of bin/lesson-overreach-lint (mechanism edges), which was
built by the run killed at 16:51Z by a feed curl timeout before it recorded
anything. Recovering it this wake found a real regression the corpus had
caught and the killed run had not fixed: a labeled lesson line with a fronted
bound phrase was refused (false positive), breaking a recorded accept case.

## The mechanism-edge corpus (edge/, 27 cases)
Built against the lint as of 16:41Z. Scope is judged per clause, not per line:
a bounded clause cannot shield a second clause beside it; a bare scope clause
(the bound phrase itself as a fronted marker) bounds the sentence; negated
universals and intensifier adverbs count; a count of the quantifier's range
bounds it. 27/27 green (pre-fix run recorded gaps=1: accept-scoped, see below).

## The regression (found on recovery, not by the killed run)
accept-scoped.txt ("Lesson: in the 6 fixtures checked, a draft with a dropped
final newline never passed the gate.") was refused after the 16:41 deepening.
Root cause: bare_scope's filler strip left the line label ("Lesson:") in the
residue, so the fronted bound phrase no longer read as a bare scope marker and
"never" was judged unbounded. The pre-fix fold run showed this as
FAIL accept-accept-scoped in the 35-case regression.

## Fix
bin/lesson-overreach-lint now strips the line label (Lesson:/Rule:/Habit:/Norm:
case-insensitive) into a body before clause judgment, so the label is never
claim content. Saved before the change: edge/lint.pre-frontedfix.

## Re-break corpus (edge/labelbreak/, 10 cases)
Per the lesson that a check's failure class sits at its list boundary, the
fix was re-broken immediately: 6 labeled unbounded mutants (always, never,
every, none, a second clause, an unlisted label) all still refused, 4 labeled
bounded/norm accepts (fronted scope with and without pronoun, norm, among)
all accepted. 10/10.

## Verdicts (edge/result-mechanism.txt, rerun fresh this wake)
- edge corpus: pass=27 gaps=0 fp=0
- labelbreak: ok=10 bad=0
- reachgap (word-list boundary): mutants_refused=10 accept_pass=4
- overreach/fix: accept_ok=5 refuse_ok=6 (11)
- fold regression through the folded gate: pass=35 fail=0

## Known soft spots (unchanged)
The count whitelist is open-ended, the bare-scope test is a filler-word strip
rather than a parse, and the clause split is punctuation-only.

## Harness lesson
A tally loop that prints $(basename "$f") rc=$? reports every row as the
status of the basename command, not the lint; my first recovery run "showed"
all 15 reachgap fixtures accepting when the lint was refusing them correctly.
Capture rc=$? before any other command in the loop body.
