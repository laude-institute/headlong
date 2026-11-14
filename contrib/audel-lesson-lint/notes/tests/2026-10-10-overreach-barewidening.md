# lesson-overreach-lint deepening: bare-scope shield (2026-10-10)

Residual broken: the fronted-scope shield was sentence-wide. `bare_scope`
matched a line whose filler-stripped residue was empty (e.g. "In the 3 cases
checked"), then `bare=1` skipped EVERY clause in the sentence, including a
later clause that widened past the checked set.

Corpus scratch/lesson-derive-gate-2026-10-10/barewidening/ (28 fixtures):
16 mutants whose judged clause escapes the checked set, by naming its own
domain as subject (every run failed / no test passes / all builds stall) or
by a widening adverb (anywhere / everywhere / elsewhere / globally /
throughout / in general / ever / again). 12 accepts whose judged clause stays
inside the checked set, including argument-position universals the marker
scopes (the gate refused every mutant).

Pre-patch binary saved as barewidening/lint.pre-barewidenfix.
Pre: 16 of 16 mutants accepted (a real false-negative class), 12 of 12
accepts accepted.
Post: 0 mutants accepted, 12 of 12 accepts accepted.

Fixes, in the order the corpus forced them:
1. Shield scoping: bare_idx records the clause index of the bare marker, and
   the skip now reaches only clauses at or after it, and only when the clause
   carries no widening adverb (widere).
2. Widen word list: globally, worldwide, throughout, in general added after
   m12/m14/m15/m16 broke the first list.
3. Coreference narrowing: a shielded clause whose universal names its own
   domain is not coreferential. The first cut refused any clause with a
   domain noun, which flipped softspot/a-countnoun.md ("in the 3 cases I
   checked, the gate refused every mutant") from accepted to refused. The
   rule that separates that accept from the m9-m13 mutants is position: a
   universal that is the clause SUBJECT names its own domain, an
   argument-position universal sits inside the claim the sample scopes.

Regression: all 154 fixtures under scratch/lesson-derive-gate-2026-10-10
judged with the pre-patch and post-patch binaries; barewidening/
regress-changes.txt is empty, so no verdict outside the new corpus changed.

Runner bug found on the way: run-all.sh globbed overreach/fix/accept-*.md
while those fixtures are *.txt, so the two lines reported FAIL against
nonexistent paths and the 11 overreach fixtures never tested the lint.
Glob corrected to *.txt; whole suite then pass=54 fail=0
(barewidening/runall-post.txt).

Known residuals: the widen word list is still a list (its edge is the
failure class); the clause split does not treat "so that" as a
subordinator; coref_verbs is a hand list.
