# Overreach-lint objpron pass (2026-10-12)

Residual attacked: the objshape note named "objplural is itself a list so an
unlisted irregular plural still hides". Probing that edge exposed a worse,
shape-closeable class in the same object-slot test: accusative object pronouns.

Both halves shown by controlled pairs (each mutant read accept pre-fix):
- the fix kept them failed / the fix handed him failed / the fix kept us failed
  (accusative pronoun objects) hid behind a false relative bound, because the
  object test keyed on the noun list, the plural/objplural list, and a proper
  name, and a pronoun is in none of them.
- "her" needed a shape not a list: it is both an accusative object (told her
  failed, so the bound is false) and a possessive determiner opening the next
  clause subject (kept her gate held). A list-based her test would have flipped
  the bounded accept to refuse, because a following singular common noun like
  "gate" is in no noun list. The rule reads a following noun by shape: her is an
  object only when the next word is a verb or function word.

Fix (bin/lesson-overreach-lint):
- objpron list (them|him|us|me) plus a her rule that refuses the bound only
  when no noun shape follows it.
- "it" is NOT a gap: it is genuinely both a clause subject (all logs the fix
  kept it failed) and an object, so it reclassifies as a bounded accept control
  (a-subj-it.md), same shape as a-nomsubj.md (checked they failed). Named residual.

Corpus scratch/lesson-derive-gate-2026-10-10/objpron/: 13 fixtures, 13 expect
rows. 5 gap fixtures flip accept->refuse (g-obj-them/him/us, g-obj-her,
g-obj-her2 dative), 8 controls hold accept. Two controls (a-gov-forus "kept for
us", a-her-green "kept her green gate held") are regression guards for
governed-preposition pronouns and possessive-her-with-adjective that the first
cut would have broken.

Canonical sweep (320 fixtures, objshape tree + all objpron fixtures):
exactly 5 flips, all in the gap class; zero other movement
(sweep-changes.txt).
Suite: 18->19 corpora (run-all.sh registers objpron), pass=372 fail=0.
Pre-patch binary: scratch/lesson-derive-gate-2026-10-10/objpron/lint.pre-objpronfix.

Residuals named for the next pass:
- the noun-shape test that reads a possessive "her" is itself a list plus shape,
  so an unlisted irregular plural right after "her" may still be missed.
- "it" stays ambiguous by construction; resolving it would need clause-role
  tracking the lint does not do.
