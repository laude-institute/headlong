# lesson-overreach-lint soft-spot pass (2026-10-10)

## What was broken
The 2026-10-10 deepening left two named soft spots, and both were real gaps.
A 13-fixture corpus (scratch/lesson-derive-gate-2026-10-10/softspot/) broke
the lint 7 of 7 ways through the count whitelist and the clause split:

- a bare number counted as a bound whatever it numbered, so "the stuck-step
  cleanup always wedges on PR 156", "the scheduler always misfires on
  2026-10-03", "in 2026 the gate always passes" and "the dispatcher always
  wedges at step 3" all passed unchecked;
- "no one" was never refused at all, since "one" matched the count word list;
- the punctuation-only clause split judged "in the 2 cases I checked the gate
  refused and the fix always holds" as one bounded clause.

## Fixes (bin/lesson-overreach-lint)
1. countre is now count-then-plural-check-noun within at most three short
   modifier words (numre x modre{0,3} x nounplre), and the noun must be
   plural: "step 3" is a location, "the 35 fixtures all pass" is a count.
2. The clause split also breaks at a coordinating conjunction when what
   follows starts with a subject.
3. Follow-on from fix 2: splitting created a false positive at the seam.
   "all three sources were checked and none failed" split into a bounded
   clause and "none failed", which then read as unbounded, even though "none"
   ranges over the same three sources. Added a narrow coreference rule: a
   coordinated clause whose only universal is a bare pronoun (none, both,
   nothing, all) with no domain of its own inherits its sibling clause's
   bound. Widening words (else, ever, anywhere, everywhere, again, ...) or a
   domain of its own ("every later build") break coreference and the clause
   is judged on its own.

## Evidence
- corpus scratch/lesson-derive-gate-2026-10-10/softspot/: 17 fixtures,
  pass=17 fail=0 after the fixes (pre-fix: 7 mutants accepted, i.e. 7 gaps).
- pre/post regression over every other corpus fixture (80 lines in pre.txt):
  the only diffs are the softspot files themselves. reachgap/a-allthree.md
  and every edge, labelbreak, overreach/fix, fold fixture keep their verdict.
- lint.pre-softspotfix keeps the pre-patch binary.

## Residual soft spots (named, per the list-boundary lesson)
- the bare-scope test is still a filler-word strip, not a parse;
- the clause split is punctuation and subject-start only: a conjunction
  joining two verb phrases with an unlisted subject stays one clause
  ("the gate refused and always holds" is not split);
- a count trailing its noun ("the fixtures, 35 of them, all pass") is not
  read as a count;
- the coreference verb list and the noun/modifier whitelists are lists, so
  their failure class sits at their edges.

## Self-refusal on the lesson draft (same day)
The folded gate refused the first draft of the lesson about this work, because
the draft quoted the refused example strings themselves while describing the
failure class. The refusal is the lint judging lesson text as claims, and it
cannot tell a quoted example from a claim. The tempting fix is a quote escape
(quoted text is exempt), which would let a quoted claim through and so is a
bypass channel, not a fix. The draft was reworded to describe the examples
instead of copying them; the exact strings stay in this note and in the
corpus, which are evidence and not lesson text.
