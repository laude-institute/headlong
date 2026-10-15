# overreach-lint seam pass (2026-10-10)

## What was broken
The soft-spot pass named this residual and it was real. The clause split was
punctuation and subject-start only, so a coordinator joining two verb phrases
under one shared subject stayed one clause, and a bound sitting in the first
verb phrase covered the second. Six lesson-shaped mutants in
scratch/lesson-derive-gate-2026-10-10/seam/ passed the lint unchecked before
the fix, each of them a bounded first phrase plus an unbounded universal in
the second: always holds, never misfires, cannot fail, invariably holds,
remains always correct, and a bare pronoun universal widened by an adverb.

## Fix
bin/lesson-overreach-lint now breaks the clause at the verb-phrase
coordinators and, but, or and nor whatever follows them, so the second verb
phrase is judged on its own. so, then, while and whereas still split only
before a subject, because so far is itself a bound phrase and a blanket split
there would destroy the bound. The header comment in the binary records this
pass and the remaining soft spots.

## Evidence
- seam corpus, 13 fixtures, pre.txt and post.txt: pre-fix 6 of 6 mutants
  accepted (6 gaps) and 7 of 7 accepts accepted; post-fix 6 of 6 mutants
  refused, 7 of 7 accepts accepted, 0 mismatches against the expectation
  encoded in the file names.
- regression sweep over every other markdown fixture under
  scratch/lesson-derive-gate-2026-10-10 (deepen, overreach, reachgap, edge,
  labelbreak, fold, softspot corpora and the lesson drafts): verdict before
  and after the patch is identical for every one of the swept files,
  regress.txt with regress-changes.txt empty.
- pre-patch binary saved as seam/lint.pre-seamfix.

## Remaining soft spots (named, per the list-boundary lesson)
- so, then, while and whereas can still join two verb phrases with no subject
  into one clause, so a bound in the first still covers the second;
- a count trailing its noun is still not read as a count;
- the bare-scope test is still a filler-word strip rather than a parse.
