Lesson (2026-10-12, objshape): an object-slot check that reads its object by noun and determiner lists misses an object outside those lists, and the noun it does see can belong to the preposition rather than the verb. The fixture the fix kept the mice failed read accept because "mice" sat outside the noun list, and kept in the tests refused a bounded accept because the walk left the preposition noun in the object slot. Reading the object as a shape (determiner plus plural or proper-name content word, or bare plural or proper name) refuses the hidden object while a determiner plus singular common noun stays out of the way, because that shape starts a new clause rather than an object.
evidence: file scratch/lesson-derive-gate-2026-10-10/objshape/pre.txt
evidence: file scratch/lesson-derive-gate-2026-10-10/objshape/post.txt
evidence: file scratch/lesson-derive-gate-2026-10-10/objshape/expect.txt
evidence: contains scratch/lesson-derive-gate-2026-10-10/objshape/pre.txt g-irrobj-det.md          accept
evidence: contains scratch/lesson-derive-gate-2026-10-10/objshape/post.txt g-irrobj-det.md          refuse
evidence: contains scratch/lesson-derive-gate-2026-10-10/objshape/post.txt g-properobj.md           refuse
evidence: contains scratch/lesson-derive-gate-2026-10-10/objshape/pre.txt a-governed-detpl.md      refuse
evidence: contains scratch/lesson-derive-gate-2026-10-10/objshape/post.txt a-governed-detpl.md      accept
evidence: cmd test $(wc -l < scratch/lesson-derive-gate-2026-10-10/objshape/sweep-changes.txt) = 0
evidence: cmd bash -c 'ok=$(grep -c "^ok" scratch/lesson-derive-gate-2026-10-10/objshape/runall.txt); fail=$(grep -c "^FAIL" scratch/lesson-derive-gate-2026-10-10/objshape/runall.txt); [ "$ok" = 359 ] && [ "$fail" = 0 ]'
