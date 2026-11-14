# Silent-skip fix (2026-10-12)

The overreach-lint runner (run-all.sh) silently skipped fixtures whose verdict
could not be resolved: a fallback prefix rule (m* -> refuse, a* -> accept,
*draft* -> accept) dropped any fixture not matching those prefixes. 31 fixtures
across probe-sop (7), reduced (4), verbtail (14), adjudicate (1), adshape (1),
and irrtail/probes (4) were never graded, so a regression in them went unseen.

Fix:
- Wrote expect.txt verdict files for the 5 flat corpora and irrtail/probes
  (verdicts derived by running ../../bin/lesson-overreach-lint on each fixture).
- Extended corpus_run() to recurse one level into subdirs (irrtail/probes).
- Added the 5 corpora to the enumeration loop.

Correction from the prior finding: deepen/ (21 fixtures) is derive-gate domain
(20/21 carry evidence: lines), NOT overreach domain, so it is correctly absent
from this runner.  It should live under bin/lesson-derive-gate testing instead.

Result before fix: pass=391 fail=0 (31 silently skipped).
Result after fix:  pass=422 fail=0, every fixture graded via expect entry.
