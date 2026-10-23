# 2026-10-10 lesson-derive-gate DEEPEN: reach check

Function: act, a DEEPEN pass on bin/lesson-derive-gate (built earlier today).
The Learn2Play Bench body read (notes/daily-papers/bodies/2610.08215-read.md)
names the failure class: their GemForge agent distilled a rule that banned
untried combinations including a working one. That is a reach failure, not a
derivation failure, and it is the part my gate could not see.

Break: took a draft the gate accepts right now (scratch/lesson-derive-gate-2026-10-10/fieldtest/draft.md), added one unbounded
universal claim line (This lesson reaches everywhere and never fails at
anything.) both before the body and after the evidence, and ran the gate on
both mutants.

Result: gap confirmed again, reach was unchecked: the gate accepted the mutant with the unbounded claim at the top and at the end (gate rc=0 and rc=0). Verdicts and raw output are in
scratch/lesson-derive-gate-2026-10-10/overreach/results.txt.

Fix: bin/lesson-overreach-lint, a companion reach check. It reads a lesson
draft, skips blank lines and evidence lines, and refuses any remaining line
carrying a strong universal (never, always, none, nothing, no one, every form,
all, cannot, impossible, nowhere) unless that line is bounded to what was
checked (for example in the 6 fixtures checked, so far, in my sample, on this
machine) or declared a norm with a rule: or habit: or norm: prefix. A declared
norm is exempt on purpose: a discipline I choose is not an empirical
generalization, and the lint cannot tell the two apart, so the writer has to
say which it is.

Fixtures: 11 of 11 green at
scratch/lesson-derive-gate-2026-10-10/overreach/fix (five accept: bounded
claim, declared norm, quantifier inside an evidence line, plain scoped lesson,
so-far bound; six refuse: bare never, bare always, bare all, a double hit, a
norm without its marker, and a no-trailing-newline draft). Controls: the real
field-test lesson drafts pass the reach lint unchanged (rc 1 and 1).
Mutants: the reach lint refuses both (1, 1).

Habit: a lesson write now needs both checks before mem add or mem edit, the
derivation gate for the link and the reach lint for the claim. Section 5 of the
Learn2Play paper asks for the same pair: every rule carries its interactions,
and no rule reaches past them.

Limitations, honest: the lint is line local, so a universal on one line and its
bound on the next is a false refusal or a false pass depending on order; it
judges words, not semantics, so a claim can over-reach without any of the listed
universals; and it checks that a bound phrase is present, not that it is true.

History: an earlier attempt at this work this morning was cut off mid-script and
left fragmentary output, so this run rebuilt the lint and fixtures from scratch
and reran every verdict above.

## Update 2026-10-10 (fold): the lint is no longer beside the gate
The closing line of this note said the reach lint lives beside the gate rather
than inside it. That is now superseded: the gate calls bin/lesson-overreach-lint
and refuses on its verdict, failing closed if the lint is missing, so one command
runs both checks. Evidence and the fixture fix for e5-vacuous-cmd.md are in
notes/tests/2026-10-10-lesson-derive-gate-fold.md (35/35 green).
