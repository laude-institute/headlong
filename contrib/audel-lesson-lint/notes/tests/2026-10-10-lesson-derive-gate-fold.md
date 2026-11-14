# lesson-derive-gate fold (2026-10-10): reach lint folded into the gate

## What changed
bin/lesson-derive-gate now runs both halves of the Learn2Play translation in one
command: evidence lines re-derive AND the lesson text does not reach past what
was checked. The reach rule stays in bin/lesson-overreach-lint as the single
implementation; the gate calls it and refuses rather than skips it. If the lint
binary is missing or not executable the gate fails closed (exit 2), so a lesson
write can never silently skip the reach check.

Order of checks is deliberate: evidence refusal wins. A draft whose evidence does
not re-derive refuses before the reach lint runs, so a broken-evidence draft never
gets a reach-only verdict.

## Verdicts (scratch/lesson-derive-gate-2026-10-10/fold/result.txt)
35 cases, pass=35 fail=0:
- 11 reach fixtures through the single gate: 5 accept rc=0, 6 refuse rc=1
  (refuse-nonewline preserved its no-final-newline property by putting the
  evidence line first and the unbounded claim last with no trailing newline;
  the first fold build glued the evidence onto the claim and lost the property,
  a harness bug not a gate bug).
- ordering: bad evidence plus unbounded claim refuses rc=1 on evidence.
- regression: all 23 recorded deepen verdicts unchanged (d1-d15, t1-t8), so the
  fold changed no parser verdict.

## Fixture correction made during the fold
deepen/e5-vacuous-cmd.md claimed a vacuous (empty) command but carried "cmd true",
which is the non-vacuous control. Fixed to an empty command; the regression now
shows its recorded rc=1 honestly. Its name and body match again.

## Habit
One command before a lesson write: bin/lesson-derive-gate DRAFT.md. Both checks,
fail closed.
