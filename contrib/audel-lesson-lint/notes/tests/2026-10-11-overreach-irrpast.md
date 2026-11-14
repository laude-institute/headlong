Lesson: a relative bound whose verb is an irregular past form was refused by the
overreach lint, and the fix is a widened verb class plus a non-past guard that
the first cut needed.

Rule: when a bound-recognition pattern is widened, widen the guard that keeps it
from reading the wrong predicate as the bound in the same step, and re-run the
whole fixture tree before and after.

Norm: an irregular past cannot be recognized by shape, so it stays a list, and
the list is the place to name the next residual rather than claim the shape is
done.

Habit: probe a named residual with a controlled pair first, two sentences that
differ only in the word suspected, before reading which path a verdict came from.

evidence: file bin/lesson-overreach-lint
evidence: contains bin/lesson-overreach-lint marked|signed|sealed|grew|grown|held
evidence: contains bin/lesson-overreach-lint modal="will|would
evidence: file scratch/lesson-derive-gate-2026-10-10/irrverb/ctl-grew.md
evidence: file scratch/lesson-derive-gate-2026-10-10/irrverb/sweep3-changes.txt

The residual named in the adjudicate note (lexical lists remaining in
relclause_ok) was real. relclause_ok recognized a relative-bound verb only by
the vb list or an ed suffix, so an irregular past in the subject chain (the
auditor grew from, the gate held) was not read as a bound and a bounded
accept was refused. The controlled pair made this certain: the same sentence
with grew from, read from or built from in the same slot flipped from refuse to
accept on the verb alone.

The first cut widened the verb class to the common irregular past and
participle forms and broke four existing refuse fixtures instead. A non-past
relative (the lint will name, the team debates) was then skipped by the search
and the past MAIN predicate after it (broke) was read as the bound. The full
before and after sweep over the fixture tree caught all four, so the widening
did not ship with the over-reach. The guard now refuses a relative bound that
carries a modal or ends in a present-tense verb.

Residual named for the next pass: the irregular list is still a list, so a past
form outside it (the fix rang, the run shone) is refused again, and the present
tense guard keys on an s suffix, so a plural noun ending the subject chain is
suspect.
