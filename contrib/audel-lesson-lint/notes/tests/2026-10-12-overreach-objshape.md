# Overreach-lint objshape pass (2026-10-12)

Residual attacked: the objslot note named "the object-slot NP check keys on the
noun and determiner lists, so an irregular-plural or proper-name object outside
them can still hide".

Both halves were real, shown by controlled pairs:
- the fix kept the mice failed / the latch flung open the geese failed
  (irregular-plural objects outside nounplre) read accept pre-fix,
- the fix kept Alice failed / the latch flung open Bob failed (proper-name
  objects) read accept pre-fix,
- while governed PPs (kept in the region, stored at GitHub, wrote for Alice)
  and plain phrasals (flung open) correctly held accept.

Pre-fix verdicts (objshape/pre.txt): 4 gap fixtures accept, controls hold.

Fixes:
1. The object-slot walk consumed only a prep+det pair (q+=2), so a governed
   PP with a real NP ("kept in the tests") left the noun in the object slot and
   a bounded accept refused (objshape/a-governed-detpl.md). The walk now
   consumes the preposition's whole NP before judging the object slot.
2. The object check keyed on the noun/determiner lists. It now reads shapes:
   a determiner plus a PLURAL or PROPER-name content NP, or a bare
   plural/proper name, is an ungoverned object and refuses the bound. A
   determiner plus SINGULAR common noun is not read as an object, because that
   shape starts a new clause ("all logs the fix kept the gate held and none
   leaked"), which the first cut wrongly refused (probelex/a-coref-leaked.md,
   a-coref-slipped.md both flipped accept->refuse on the 441-fixture sweep and
   were the sweep catching an over-reach). Irregular plurals (mice, geese,
   people, corpora...) are recognized by an objplural shape since the
   [a-z]+(s|es) form cannot read them.

Verification:
- Corpus 12 fixtures, expect.txt written; pre vs post exactly 5 flips
  (4 gaps accept->refuse, a-governed-detpl refuse->accept) and zero others
  (objshape/pre.txt, post.txt).
- Same-set sweep over the canonical 441-fixture tree list
  (particle/sweep-list.txt): zero verdict movement (objshape/sweep-changes.txt
  empty).
- run-all.sh now runs 19 corpora (objshape added): pass=359 fail=0
  (objshape/runall.txt).

Pre-patch binary: scratch/lesson-derive-gate-2026-10-10/objshape/lint.pre-objshapefix

Residual named for the next pass: irregular-past phrasal verbs whose particle
is outside the particle list (cut loose, sprang aside, tore together) are still
refused as relative bounds, and the objplural shape is itself a list, so an
unlisted irregular plural (e.g. oxen, kine) still hides.
