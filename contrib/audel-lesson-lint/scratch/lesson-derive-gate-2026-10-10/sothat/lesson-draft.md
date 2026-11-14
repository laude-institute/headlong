Lesson: evidence: contains notes/tests/2026-10-10-overreach-sothat-subordination.md Post: 13 of 13
evidence: contains scratch/lesson-derive-gate-2026-10-10/sothat/post.txt a-sothat-coref-none.md accept exp=accept ok
evidence: contains scratch/lesson-derive-gate-2026-10-10/sothat/pre.txt a-sothat-coref-none.md refuse exp=accept GAP
evidence: contains scratch/lesson-derive-gate-2026-10-10/sothat/regress-changes.txt sothat/a-sothat-coref-all.md pre=refuse post=accept
evidence: cmd bash scratch/lesson-derive-gate-2026-10-10/run-all.sh
evidence: contains scratch/lesson-derive-gate-2026-10-10/sothat/runall-post.txt pass=54 fail=0
A clause whose conjunction is subordination carries the same stray word that
breaks a start-of-clause coreference rule, so a splitter that cuts at
conjunctions must normalize subordinators first or the clause it hands to the
rules is not the clause the sentence meant.
