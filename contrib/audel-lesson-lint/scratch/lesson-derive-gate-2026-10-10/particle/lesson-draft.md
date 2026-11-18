Lesson (2026-10-11, overreach-lint particle list): when two code paths judge the same notion by shape, the fix for one is the fix for both, and a partial fix shows up as a fixture pair that differs in one word. The relcl verb search read a phrasal past by shape (verb slot word plus particle) while hasmain beside it read only its verb list and an ed suffix, so a relative ending in a phrasal main predicate dropped its bound even though the same relative ending in a simple past kept it.

Rule: when a guard discriminates two lookalikes, land the discriminator in both places the lookalike is judged. Fixing only the search leaves the guard reading the second case wrongly, and the corpus pair that proves it is the two fixtures that differ in the verb after the relative.

Norm: the particle list is widened and hasmain now uses the verb shapes plus the particle shape the search uses. The named gap pair moved refuse to accept and no other verdict moved in the tree.

Residual named for the next pass: the particle list is still lexical, so a multiword particle like "set in motion" is read through its first word only, and irregular-past phrasal verbs outside the widened list stay unread.

evidence: file scratch/lesson-derive-gate-2026-10-10/particle/expect.txt
evidence: file scratch/lesson-derive-gate-2026-10-10/particle/sweep-sameset-changes.txt
evidence: contains scratch/lesson-derive-gate-2026-10-10/particle/sweep-sameset-changes.txt a-flungopen.md
evidence: contains scratch/lesson-derive-gate-2026-10-10/particle/sweep-sameset-changes.txt a-keepphrasal-main.md
evidence: cmd test $(wc -l < scratch/lesson-derive-gate-2026-10-10/particle/sweep-sameset-changes.txt) = 2
evidence: cmd bash -c 'ok=$(grep -c "^ok" scratch/lesson-derive-gate-2026-10-10/particle/runall.txt); fail=$(grep -c "^FAIL" scratch/lesson-derive-gate-2026-10-10/particle/runall.txt); [ "$ok" = 333 ] && [ "$fail" = 0 ]'
evidence: contains bin/lesson-overreach-lint root|online|ahead|apart
