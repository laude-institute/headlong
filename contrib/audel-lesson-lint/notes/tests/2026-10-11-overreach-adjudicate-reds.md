# overreach-lint: adjudicating the 19 pre-existing reds (2026-10-11)

The vbshape pass left 19 red fixtures in adjrel, lexedge and sharedvp
unadjudicated. All 19 were real gaps; each was fixed and the fix verified by a
before/after sweep of all 366 fixtures in the tree.

## Mechanisms (five families)

1. Modifier-reading coreference (adjrel m-adjkept/known/made/set, lexedge
   m-{built,known,read,sent,shown}-*): a predicate-list word used as a noun
   modifier ("all kept records failed", "all built machines failed") matched
   the bare-predicate coreference test and the clause skipped as coreferential.
   domain_self now reads the modifier shape (predicate word + plural noun +
   trailing main predicate). The trailing predicate was forced by a re-break:
   without it "all ran tests" (bare subject, verb, object) was misread as a
   modifier and lexedge/a-ran-tests flipped to refuse.
2. Both-detector (adjrel m-bothcorpora, m-bothcurricula, m-both-5mod): the
   both+plural-noun pattern keyed on the nounplre lexicon and a three-word
   modifier chain, so irregular plurals (corpora, curricula) and longer chains
   named no domain. bothre is a shape now.
3. Wrong-head relative bound (adjrel m-objrel): bound_in matched the raw
   rcbre pattern at any noun, so "all runs failed the checks the log read"
   got a bound from the wrong head. The raw pattern no longer bounds alone;
   relclause_ok (with its head restriction) is the test.
4. Relative-subject list (lexedge a-rcdet-poss, a-rcdet-this): determiners and
   pronouns only, so "my check flagged" and "this check flagged" read as no
   relative clause and refused a bounded accept. Possessives and
   demonstratives qualify now.
5. Shared-VP continuation (sharedvp a1/a2/a4, softspot/a-andverb): a clause
   the seam split created carries its subject from the sibling ("the 3
   fixtures I built and re-ran all pass"), so a bare universal with a listed
   predicate ending that clause ranges over the checked set.

Plus one widenedge-class gap found while recording rows: sharedvp/r1 ("keeps
failing forever") never got judged because forever is outside qre.
forever/permanently join qre and widere.

## Expectation rows

softspot/lesson-draft.md refuses correctly (quoted bug strings read as
claims); the *draft* fallback expected accept, so that red was a wrong
expectation, not a gap. sharedvp/r1-r3, vbshape/a-quantrel-every and
a-unlist-dropped had no rows and were silently skipped. Writing a partial
expect.txt blinds the unlisted fixtures of that corpus (runner reads rows
exclusively once the file exists), which cost 14 passes on the first attempt;
all fourteen corpora now carry complete rows and the runner judges every
fixture (0 skipped).

## Other fixes and evidence

run-all.sh ran fold/harness from the corpus dir while recorded.txt paths are
workdir-relative, a cwd artifact that made fold read as red under the suite
and green standalone; it now runs from the workdir root.

Evidence: scratch/lesson-derive-gate-2026-10-10/adjudicate/ (pre binaries
lint.pre-adjudicatefix and lint.pre-foreverfix, probe.sh, verify2.txt,
regress3-changes.txt: 366 fixtures, exactly the intended 22 flips).
Suite pass=291 fail=0 (was 250 pass / 21 fail).
