# Overreach-lint objslot pass (2026-10-11)

Residual attacked: the particle pass note named "a multiword particle like
set in motion is read through its first word only". Probing showed the real
defect behind it: an object hiding behind the particle phrase (or straight
after the verb) let a false relative bound pass, so four lesson-shaped gap
fixtures read as accept.

Pre-fix verdicts (objslot/pre.txt), the four gaps:
- g-hiddenobj-aftermw.md  accept  "all logs the fix set in motion the tools failed"
- g-hiddenobj-afterpart.md accept "all logs the latch flung open the tools failed"
- g-hiddenobj-bareplural.md accept "all logs the latch flung open tests failed"
- g-hiddenobj-plain.md    accept  "all logs the fix kept the tools failed"

Mechanism: relclause_ok reads a relative verb by shape (verb list, ed suffix,
or verb-slot word plus particle). It only checked for a bare plural noun
directly after the verb. A particle phrase hides the object one slot further
("flung open the tools"), a preposition plus bare singular continues a
multiword particle ("set in motion"), and a determiner noun phrase after the
verb ("kept the tools") was never checked at all. In all four the relative
verb does not take the head as its object, so the bound is false.

Fix: after the verb is found, walk past the particle/preposition phrase to
the object slot. A preposition followed by a determiner NP, a plural noun, or
a bare singular that continues a multiword particle is governed and skipped;
anything left in the slot that is a determiner noun phrase or a plural noun is
an ungoverned object and the bound is refused.

Controls holding post-fix (objslot/post.txt): set in motion, set at bay,
took in hand, took root, flung open, and governed PPs (kept in the region,
stored in tests) stay accept; flung metal, set the tests aside, adj open,
tools noun, takes root stay refuse.

Verification:
- Corpus 14 fixtures, expect.txt written; pre vs post exactly the 4 gap
  flips accept->refuse and zero others (objslot/pre.txt, post.txt).
- Same-set sweep over the 441-fixture tree list (particle/sweep-list.txt):
  zero verdict movement (objslot/sweep-changes.txt empty).
- run-all.sh now runs 18 corpora (objslot added): pass=347 fail=0
  (objslot/runall.txt).

Pre-patch binary: scratch/lesson-derive-gate-2026-10-10/objslot/lint.pre-objslotfix

Residual named for the next pass: the object-slot NP check keys on the noun
and determiner lists, so an irregular-plural or proper-name object outside
them can still hide, and irregular-past phrasal verbs whose particle is
outside the particle list (cut loose, sprang aside, tore together) are still
refused as relative bounds.
