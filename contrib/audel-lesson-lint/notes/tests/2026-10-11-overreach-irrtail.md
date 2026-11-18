Lesson: the two residuals the irrpast note named were real, and the first was
not another verb list but a phrasal-verb shape, while the second was a guard
keyed to the wrong discriminator.

Rule: when a guard keys on a word shape, name the case it is for and land the
discriminator that separates it from the lookalike in the same step. The
s-suffix present guard exists for a skipped present relative verb, which is
exactly the case where a verb does not follow the word the search found, so a
verb following it proves the chain ended in a plural noun instead.

Norm: a phrasal past is recognized by shape (a word in the verb slot followed
by a particle), so it does not join the verb list, and the particle list is the
place to name the next residual rather than claim the shape is done.

Habit: settle the fixture set before the final before and after sweep, so probe
duplicates left in the tree do not inflate the flip count I report.

evidence: file bin/lesson-overreach-lint
evidence: contains bin/lesson-overreach-lint hasmain=0
evidence: contains bin/lesson-overreach-lint particle="(in|of|from|among
evidence: file scratch/lesson-derive-gate-2026-10-10/irrtail/expect.txt
evidence: file scratch/lesson-derive-gate-2026-10-10/irrtail/sweep-sameset-changes.txt

The two residuals named at the end of the irrpast pass were real, shown by a
controlled pair differing in one word apiece. The past form outside the widened verb
list (the fix rang out, the run shone on, the fix flew past) left a bounded
accept refused because relclause_ok read a relative verb only from the vb list
or an ed suffix. The plural object noun ending the relative subject (the
reviewer notes kept, the team tests ran) tripped the non-past s-suffix guard
and dropped the bound the same way.

The fix for the first is a shape rather than a longer list: a word in the verb
slot that is not a function word and is followed by a particle reads as the
relative verb, and it takes the same carve-outs as an ed verb. The fix for the
second is the discriminator the guard was missing: a later listed or ed verb
means the search found the relative verb and the chain ended in a plural noun,
so the bound stands; without one the guard keeps its refuse.

The corpus scratch/lesson-derive-gate-2026-10-10/irrtail/ holds 15 fixtures
with 15 expect rows, 10 bounded accepts and 5 controls, and the 15 verdicts
recorded there hold after the fix. The final sweep ran both binaries over one settled 433 fixture
tree: 12 flips, bounded accepts in the two gap classes above (8
irrtail fixtures plus 4 earlier probes of the same classes), and the other 421
verdicts did not move.

Residuals named for the next pass: the particle list is still lexical, so the
latch flung open stays refused; and hasmain keys on the vb list and an ed
suffix, so an irregular main predicate after the relative (the reviewer notes
kept rang out) still drops the bound.
