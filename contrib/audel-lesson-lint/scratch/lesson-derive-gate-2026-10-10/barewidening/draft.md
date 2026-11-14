Lesson (2026-10-10, bare-scope shield): in the 28 fixtures checked, a scope bound fronted at the start of a sentence was shielding the clauses after it, so one of those clauses could widen past the checked set and still read as bounded. 16 of the 16 widening mutants passed before the fix and 0 after; the fix that held gave the shield clause reach and clause reach only, so it covers the clauses at or after the marker and stops at a clause that names its own domain.
rule: a scope bound belongs to a clause, not to a line or a sentence; state the reach of any shield you grant and break the case where it reaches too far.
evidence: file notes/tests/2026-10-10-overreach-barewidening.md
evidence: cmd test "$(grep -c '^A m' scratch/lesson-derive-gate-2026-10-10/barewidening/pre.txt)" = 16
evidence: cmd test "$(grep -c '^A m' scratch/lesson-derive-gate-2026-10-10/barewidening/post.txt)" = 0
evidence: contains scratch/lesson-derive-gate-2026-10-10/barewidening/runall-post.txt pass=54 fail=0
evidence: cmd test ! -s scratch/lesson-derive-gate-2026-10-10/barewidening/regress-changes.txt
evidence: cmd test -x bin/lesson-overreach-lint
