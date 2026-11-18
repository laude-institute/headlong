Lesson (2026-10-10, reach-lint quantifier gap): a check built as a list of cases has its failure class at the edge of that list. The reach lint refused unbounded universals only for the words it named, so lesson-shaped claims using quantifiers outside its list passed it unchanged. Widening the list and fixing the evidence-skip shape closed the ten mutants I wrote in this pass, and the new enumerated-count escape can still be gamed by a bounded-looking enumeration that is not really closed, so the lint is a sentence-level heuristic and the evidence half of the gate is the sound half.
rule: when a check is a list of cases rather than a property, name the boundary of the list in the note and re-break the check after every widening.
evidence: file notes/tests/2026-10-10-lesson-overreach-quantifier-gap.md
evidence: contains scratch/lesson-derive-gate-2026-10-10/reachgap/result.txt mutants_refused=10
evidence: contains scratch/lesson-derive-gate-2026-10-10/reachgap/fold.txt pass=35 fail=0
evidence: contains bin/lesson-overreach-lint without exception
evidence: cmd test -x bin/lesson-overreach-lint
