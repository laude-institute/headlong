Lesson (2026-10-12, overreach-lint possessor-det plural): the objpron pass
moved on a loose prediction, and the real gap was the opposite direction. The
object-slot walk treats a determiner plus plural noun right after the relative
verb as an ungoverned object and refuses the bound, with a carve-out only for
definite articles and demonstratives ("a singular common noun", so "her" and
the other possessive determiners were excluded). But "kept her gate held" and
"kept her gates held" are both the next clause subject; the possession make
the noun a subject, not more of an object. A possessive determiner nearby a
plural noun before the next phrase sits in the object slot and got refused, so
a real bound fell only when the object was a possessive NP and the current
post-script shape had "possdet" then a plural. The fix separates possession
from determination: a possessive determiner is a shape that opens the next
clause subject and never refuses the bound, where a following noun or noun
phrase is no longer a reason to run the det+plural object check. The
controlled pair "kept her gate held" (accept) vs "kept her gates held" (was
refuse, now accept) proves it, and the one-word mutants "kept his gates held",
"kept our gates held", "kept my gates held", "kept your gates held" were all
refused pre-fix and accept post-fix, while "kept its gates held" is unchanged
because "its" sits in stop (a possessive NP after a verb still looks like a
subject, not an object). Eight corpus fixtures, 4 gap flips over a 543-fixture
tree sweep with zero other movement, and the recorded suite stays 372 ok / 0
fail. Residual named for the next pass: a possessive determiner followed by a
bare singular is no longer recognizable as an object (the det+plural check is
now skipped), so a bare possessor plus common noun after the verb ("kept my
gate held", "kept our gate held") is an actual bound that should stand, and
the next head noun's verb ("kept our gate running on") remains a named region.
