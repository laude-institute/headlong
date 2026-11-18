# Overreach-lint herplural pass (2026-10-12)

Residual attacked: the objpron note named "the noun-shape test that reads a
possessive her is itself a list plus shape, so an unlisted irregular plural
right after her may still be missed". Probe showed the miss was in the
RELATIVE-BOUND HEAD SEARCH, not the object-slot her rule.

Probe (isolated awk of relclause_ok): w2 nounmatch no for mice, geese, foci,
bacteria; yes for logs, theses, children. noun= was a lexical list. So "all
her mice the fix kept failed" (universal domain = possessive her plus irregular
plural) refused as unbounded because the bound search never found the head.

Fix (bin/lesson-overreach-lint, one line): widened relclause_ok noun= with the
irregular plurals the objplural list already knew about (mice geese feet teeth
lice oxen quanta alumni cacti fungi nuclei stimuli). The object-slot her rule
and objpron lists are untouched.

Prosper corpus scratch/lesson-derive-gate-2026-10-10/herplural/: 11 fixtures,
11 expect rows. 5 gap flips refuse->accept (a-all-her-{mice,geese,oxen,teeth,
feet}), 6 controls hold (bare-her refuses x2; her+listed-noun subjects accept
x4). Link to objpron 13-fixture corpus: exactly these 5 flips, zero other
movement.

Canonical sweep (544 saved fixtures minus herplural): zero changes in
sweep-pre/post diff.

Suite: run-all.sh registers herplural as a 20th corpus, pass=383 fail=0.
Pre-patch binary: scratch/lesson-derive-gate-2026-10-10/herplural/lint.pre-herpluralfix.

Residuals named for the next pass:
- the same noun list exists in plnoun= for the both-re and in countre's
  nounplre, so irregular plurals can still hide in EITHER direction of those
  checks now.
- the her rule reads the following noun by a shape (content word not a verb or
  function word), and while a list-added irregular plural (mice) now falls in
  that shape accept branch, an irregular plural ending in ed/en (kept her
  bacteria settled) may read as a vshape verb and still hide.
