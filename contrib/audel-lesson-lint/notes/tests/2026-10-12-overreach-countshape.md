# Overreach-lint countshape pass (2026-10-12, corrected)

Residual attacked: countre still keyed on the lexical nounplre list, so a
count followed by a noun outside the list ("in the 35 cohorts all passed",
"in the 4 corpora all passed", "in the 10 theses all passed") read as
unbounded and refused.

First cut was wrong: replacing the list with the broad plnoun shape
(a-z+(s|es)) flipped two protected fixtures, softspot/m-noone and
irrtail/m-toolsused, because a third-person present verb ("no one gets the
reply shape right": one + gets + determiner) and a relative-subject count
noun ("the 3 tools used") read as count domains under the broad shape.
Running the full suite after the patch caught both; I had first assumed they
were pre-existing without checking, which is the verification miss this pass
teaches.

Fix: countre kept on nounplre, which gained cohorts|corpora|theses (one
line). That closes the named gap while the list's narrowness keeps the two
protected shapes excluded.

Verification: countshape corpus scratch/lesson-derive-gate-2026-10-10/countshape/
7 fixtures, 7 expect rows. Gap fixtures a-count-cohorts/corpora/theses
flipped refuse->accept; controls a-count-files/rules/a-step3/a-pr156 held
accept. Full suite pass=390 fail=0 across 21 corpora. Pre-patch binary
countshape/lint.pre-countshapefix. run-all.sh registers countshape as a
21st corpus.
