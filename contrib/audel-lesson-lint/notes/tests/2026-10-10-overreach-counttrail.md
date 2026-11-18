# overreach-lint deepening 2026-10-10: trailing count (counttrail corpus)

## What broke
The named residual "a count trailing its noun is not read as a count" was real.
13 lesson-shaped fixtures in scratch/lesson-derive-gate-2026-10-10/counttrail/:
the four bounded accept shapes ("the fixtures, 35 of them, all pass",
"the runs I built, 12 in total, all succeeded", "the drafts checked, 6 of them,
all cleared", "the corpus cases (27) all pass") were all REFUSED pre-fix,
because countre only reads the count before its noun. 6 controls and mutants
behaved as intended pre-fix (pre.txt: 4 GAPs, all on the accepts).

## The fix
A sentence-level appositive rule (appre): a count phrase trailing a plural
check noun (N of them, N in total, or a parenthesized N) plus a bare universal
with a listed verb bounds that sentence, but only when the sentence carries no
adverbial quantifier of its own (advre: always, never, cannot, invariably, at
all times, every, each, any, without exception). With an adverbial quantifier
the clause loop judges it, where a trailing count sitting in its own clause
does not reach the quantifier clause (m-count-then-adv refused). A bare
universal with its own domain noun (all engineers agree) or an unlisted verb is
not treated as coreferential (m-trailing-owndomain refused).

## Verdicts
counttrail post.txt: 13/13 green (4 trailing-count accepts now accepted, 6
controls unchanged, 3 new mutants refused). Regress sweep over every other
fixture under scratch/lesson-derive-gate-2026-10-10/: zero verdict changes
(regress-changes.txt empty). Pre-patch binary saved as counttrail/lint.pre-countfix.

## Residual named for the next pass
A trailing count does not reach a coordinated adverbial clause: "the fixtures,
35 of them, all pass and never fail" is refused (m-count-then-adv), which is
conservative but not the sentence's full bound. Also unchanged: the
filler-strip bare-scope test and the so/then/while/whereas coordinator group
joining two verb phrases into one clause.
