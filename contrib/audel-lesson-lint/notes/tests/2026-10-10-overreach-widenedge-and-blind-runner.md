# 2026-10-10 widenedge pass (lexical coref + widening adverbs) and the blind runner

## What broke and what fixed it (widenedge corpus, 15 cases)
Three named residuals from the barewidening header were confirmed real, plus two
bugs found on the way:

1. Lexical coref predicate list: "none leaked", "all vanished", "nothing slipped
   through" read as coreferential-accept only when the verb was in a hand list;
   any unlisted past tense made the clause look domain-self and refuse. Fix:
   past-participle/-ed heuristic (predre) with the irregular list kept as a
   second arm.
2. Unlisted widening adverbs slipped past the fronted-scope shield ("later",
   "afterward", "from now on", "going forward", "eventually"). Fix: widere
   widened to a 22-term list.
3. BUG: coref_ok's trailing sed was s/pat\\b/I (unterminated `s`), so sed errored,
   grep saw empty input and the domain-self test never fired; coref_ok returned 0
   for every candidate clause ("none failed in every new build" skipped as
   coreferential even though domain_self named its domain). Fix: s/pat\\b//I.
4. BUG: the clause split's blanket " then " cut "from then on" into "nothing
   broke from" + "on", so widere never saw the phrase. Fix: FROMTHENONG marker
   swap around the split, like SOFARBOUND.
5. Shield-domain trailing phrase: "none failed in every new build" now refused
   (domain_self check inside coref_ok).

Result: widenedge 15/15, pre-fix gap count 9 (3 false refuses + 6 gaps).

## Adjudicated corpus conflict (a-coref-all)
My widening additions flipped softspot/a-coref-all.md ("...all passed later"):
trailing "later" shifts the claim past the checked period, the same overreach
class as "ever/anywhere", so refuse is right. Fixture split: the text stays as
softspot/m-coref-temporal.md (refuse) and the bounded coreference accept keeps
the shape without the adverb (a-coref-all.md).

## The blind runner (this is the important part)
run-all.sh covered only edge, reachgap, overreach/fix and fold. It never ran
softspot, seam, counttrail, barewidening, sothat or widenedge, so every "pass=NN
fail=0" since those corpora were born spoke for 4 of 9 corpora only.

What it hid:
- softspot/a-andverb.md ("the 3 fixtures I built and re-ran all pass") flipped
  accept->refuse in the SEAM pass (verified against all 6 saved pre-patch
  binaries: accept through seam/lint.pre-seamfix, refuse from counttrail/lint.pre-countfix on).
- seam/regress-changes.txt is NOT empty: it holds exactly that one row, while
  the seam pass's report said the sweep showed zero verdict changes. That claim
  in my record is false and is superseded by this note.
- softspot/lesson-draft.md is refused by every saved binary too (pre-existing):
  the lint judges quoted bug text inside lesson prose ("no one", "none failed")
  as lesson claims. Named residual: quoted examples of past defect text need an
  exemption.

Fix: run-all.sh (sibling run-all.sh.pre-runnerfix kept) now runs all 9 corpora
with per-corpus expectation resolution (expect.txt / expected.tsv / m-*,a-*
prefix). Fresh run: 155 checks, pass=155 minus the 2 named pre-existing reds,
i.e. fail=2 (softspot/a-andverb.md, softspot/lesson-draft.md), both refused by
every pre-patch binary as well, so today's widenedge patches caused zero
regressions (199-fixture tree sweep: 1 change, the adjudicated a-coref-all).

## Open (left for a next pass)
- softspot/a-andverb.md: red since the seam clause-split cut "built and re-ran".
  Either the split needs a shared-subject verb-phrase exception or the fixture
  expectation needs re-adjudication. Do not silently flip the fixture.
- Quoted-bug-text exemption for lesson prose.
- barewidening header residuals still open: widening adverbs outside widere is
  still a list (its edge is the failure class).
