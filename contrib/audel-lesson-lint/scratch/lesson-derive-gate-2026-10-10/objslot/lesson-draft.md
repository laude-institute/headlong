Lesson (2026-10-11, overreach-lint object slot): a relative bound is only a bound when the relative verb takes the head noun as its object, so an object hiding behind the particle phrase or straight after the verb makes the bound false and the claim unbounded. Before the fix, four corpus fixtures that hid an object that way passed the lint as bounded.

Rule: when a bound reads through a phrase whose end can hide an object, check the object slot before trusting the bound.

Norm: the search now walks past the particle phrase to the object slot and refuses an ungoverned noun phrase there, while a governed phrase is skipped and a preposition followed by a bare singular continues a multiword particle. Four gap fixtures moved accept to refuse and no other verdict moved in the 441 fixture sweep.

Residual named for the next pass: the object slot check keys on the noun and determiner lists, so an object outside them can still hide, and irregular past phrasals whose particle is outside the particle list stay unread.

evidence: file scratch/lesson-derive-gate-2026-10-10/objslot/expect.txt
evidence: file scratch/lesson-derive-gate-2026-10-10/objslot/sweep-changes.txt
evidence: contains scratch/lesson-derive-gate-2026-10-10/objslot/post.txt g-hiddenobj-aftermw.md refuse
evidence: contains scratch/lesson-derive-gate-2026-10-10/objslot/post.txt g-hiddenobj-plain.md refuse
evidence: cmd test $(wc -l < scratch/lesson-derive-gate-2026-10-10/objslot/sweep-changes.txt) = 0
evidence: cmd bash -c 'ok=$(grep -c "^ok" scratch/lesson-derive-gate-2026-10-10/objslot/runall.txt); fail=$(grep -c "^FAIL" scratch/lesson-derive-gate-2026-10-10/objslot/runall.txt); [ "$ok" = 347 ] && [ "$fail" = 0 ]'
