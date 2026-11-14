# overreach-lint DEEPEN: directory-enumerating sweep

Date: 2026-10-12T12:27:42Z
Binary: contrib/audel-lesson-lint/bin/lesson-overreach-lint (committed)
Corpus root: scratch/lesson-derive-gate-2026-10-10 (46 dirs on disk)

The committed run-all.sh tests a hardcoded list of 24 corpus names while
46 corpus directories exist on disk. This sweep resolves an expectation
for every *.md fixture in every directory (expect.txt, expected.tsv, else
the m-refuse/a-accept prefix rule, same as the runner) and runs the same
binary. It is the widen-edge/blind-runner lesson applied one level up:
enumerate directories instead of remembering a list.

Result: pass=430 fail=6 skip=91.

Per-dir detail: scratch/deepen-break-enumerate/summary.txt
Per-fixture detail: scratch/deepen-break-enumerate/detail.txt

## Adjudication of the 6 FAILs (2026-10-12T12:33Z)

All six FAILs are wrong expectations from the sweep, not lint defects.
The sweep resolves unrecorded corpora by the m-refuse / a-accept prefix
rule, and that rule overrides each corpus's own recorded intent, which
the committed runner also does (run-all.sh lines 48-67: expect.txt,
else expected.tsv, else the prefix rule). Verified by running the
committed binary against every fixture and comparing to the corpora's
own records:

1. mwpart a-cutloose / a-sprangaside / a-sprangforward / a-toretogether:
   the corpus pre.txt records all four as refuse, and the objslot note
   names them as the still-unfixed residual (irregular-past phrasal
   verbs whose particle sits outside the particle list: cut loose,
   sprang aside, tore together). The binary refuses both pre and post
   the old mwpart fix, so there is no regression; the a- prefix simply
   mislabels a named known-gap fixture as accept.
2. objpart a-oxen: pre.txt records refuse. The objshape note names the
   unlisted irregular plural residual (oxen, kine still hides). Binary
   refuses; prefix rule mislabels.
3. redpass a-redpass-builds: the lint source (line 331) names this exact
   shape, "all builds checked passed", as a deliberate reduced-passive
   refuse. Siblings a-redpass-measured and a-redpass-named accept, so the
   rule is behaving as written; the fixture name carries the wrong
   expectation.

Two extra findings dropped out of comparing full records against the
binary, and both of them say the real defect is in the expectation
layer, not the lint:

- objpart/g3 (kept the sheep) and g4 (kept those sheep) are recorded
  accept in a pre.txt dated before commit 8257044, and the binary now
  refuses both. That is the objnp fix working as intended (invariant
  plural head plus a shaped past verb = refuse), so the record is stale,
  not the binary wrong.
- The committed runner hardcodes 24 corpus names (line 80) while the
  tree has 46 dirs carrying .md fixtures, so 22 corpora never run and
  their verdicts are never certified in the suite. The enumeration gap is
  real and matches a lesson I stored already: a runner certifies exactly
  the corpora it lists.

Conclusion: no lint change is warranted from this sweep. The structural
fix is in the expectation layer, not the checker: enumerate corpus dirs
in run-all.sh and resolve verdicts from a recorded file, dropping the
prefix fallback for corpora that are not simple name-pairs, then write
expect.txt for mwpart, objpart, objpart2, redpass, coord and possher
from the current intended verdicts.
