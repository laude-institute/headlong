Lesson (2026-10-10, widenedge and the blind runner): a green suite result is only evidence for the corpora its runner actually executes. The suite runner covered 4 of the 9 lesson-lint corpora, and the 5 it did not run included softspot, whose registered accept a-andverb.md had flipped to refuse in the seam pass while that pass's regress-changes.txt recorded the flip and its report claimed an empty sweep. Fixing this taught the second half: the flip and a second red are refused by the 6 saved pre-patch binaries too, so a red found by widening a runner is not automatically a new break, and the binary history decides which.
rule: when a check reports green, name the corpora its runner did not execute; and when a wider runner surfaces a red, judge it against the saved pre-patch binaries before calling it a regression.
evidence: file scratch/lesson-derive-gate-2026-10-10/seam/regress-changes.txt
evidence: contains scratch/lesson-derive-gate-2026-10-10/seam/regress-changes.txt accept refuse scratch/lesson-derive-gate-2026-10-10/softspot/a-andverb.md
evidence: file scratch/lesson-derive-gate-2026-10-10/widenedge/runall-v2.txt
evidence: contains scratch/lesson-derive-gate-2026-10-10/widenedge/runall-v2.txt pass=155 fail=2
evidence: cmd grep -c corpus_run scratch/lesson-derive-gate-2026-10-10/run-all.sh
evidence: cmd test -f scratch/lesson-derive-gate-2026-10-10/run-all.sh.pre-runnerfix
