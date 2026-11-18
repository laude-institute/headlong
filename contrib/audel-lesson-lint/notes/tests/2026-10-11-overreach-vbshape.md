# overreach-lint vbshape pass (2026-10-11): the relative verb is a shape, not
# a list, and one relcl probe was recorded the wrong way round

The relcl pass left two residuals named in its header, and testing them
turned up a recording error in that pass rather than a new mechanism.

Residual 1 (the lexical verb list) was real and is the real bug.
relclause_ok read the relative verb from a hand list, so a past verb outside
that list read as no relative verb and the clause held the domain bare:
three bounded lessons were refused (vbshape/a-unlist-clipped,
a-unlist-appended, a-subjpron-clipped). The fix is a verb shape (a word
ending in -ed) added to the list, with three carve-outs that keep the
shallow lookalikes out. The relative verb takes the head noun as its object,
so a plural noun between the head and the next predicate stays refused
(m-modifier-flaglogs). A modifier chain is not a relative clause, so a
preposition first after the head stays refused (m-modifier-shaded). A lone
determiner is not a relative subject, so the reduced passive stays refused
(m-reduced-clipped). An adverb between head and verb and a bare adjective
there stay refused too (m-subjadv-often, m-subjadj-green).

Residual 2 (a relative clause whose subject is itself a quantifier) is not a
gap. The quantifier-subject shape was accepted before my change, and so were
the same shapes with a plain subject or with the determiner omitted
(p4-plainsubj, p5-thatdet, p6-quantnodet accepted pre-patch; see
vbshape/pre.txt). The residual the relcl header names describes a gap that
was not there.

Recording error on top of that: relcl/m-rebreak-clipped.md is byte identical
to the fixture this pass names a-unlist-clipped, but the relcl corpus
recorded it as a re-break probe expecting a refuse. That expectation
contradicts the residual the same header says it fixed. I adjudicate the
fixture as a bounded accept: relcl/a-* and m-rebreak-clipped accept, while
m-rebreak-future and m-rebreak-reduced refuse. relcl/expect.txt now records
this adjudication explicitly instead of falling through to the prefix rule.

Widened runner on the way out. The suite runner covered 10 corpora; adjrel,
lexedge and sharedvp sat outside it the same way softspot once did, so the
relcl-era flips in them were only seen by the ad-hoc tree sweep. I added
those three plus the vbshape corpus (14 corpora total) and the suite reports
pass=250 fail=21. The 21 reds are pre-existing: the pre-patch binary gives
the same verdict for the 21 (vbshape/lint.pre-vbshapefix), so the vbshape
change caused zero of them. Two are the known softspot reds, and 19 are
unadjudicated gaps from earlier passes whose corpora the runner had not run
together: adjrel and lexedge mutants the lint reads as bounded, and
sharedvp accepts the lint refuses. The tree sweep over 348 fixtures shows
8 flips (sweep-changes.txt), 7 toward the expected verdict and 1 being the
adjudicated polarity flip above. The .txt fixtures show zero flips.

Lesson (2026-10-11, overreach-lint vbshape): when a probe fixture's recorded
expectation contradicts the residual the same pass says it fixed, read the
fixture text against the mechanism before trusting the suite, because a
green suite can be green on the wrong polarity.

evidence: file scratch/lesson-derive-gate-2026-10-10/vbshape/pre.txt
evidence: file scratch/lesson-derive-gate-2026-10-10/vbshape/sweep-changes.txt
evidence: contains scratch/lesson-derive-gate-2026-10-10/vbshape/runall.txt pass=250 fail=21
evidence: cmd test "$(bin/lesson-overreach-lint scratch/lesson-derive-gate-2026-10-10/vbshape/a-unlist-clipped.md >/dev/null 2>&1; echo $?)" = 0
evidence: cmd test "$(bin/lesson-overreach-lint scratch/lesson-derive-gate-2026-10-10/vbshape/m-reduced-clipped.md >/dev/null 2>&1; echo $?)" = 1
evidence: cmd test "$(bin/lesson-overreach-lint scratch/lesson-derive-gate-2026-10-10/vbshape/m-modifier-flaglogs.md >/dev/null 2>&1; echo $?)" = 1
evidence: cmd diff -q scratch/lesson-derive-gate-2026-10-10/vbshape/a-unlist-clipped.md scratch/lesson-derive-gate-2026-10-10/relcl/m-rebreak-clipped.md
