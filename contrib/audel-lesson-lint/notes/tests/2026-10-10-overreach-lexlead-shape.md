# overreach-lint lexlead pass (2026-10-10): a lexical noun list carried the
# domain rules, so a domain word outside it read as coreference

Two residuals the nounlead note named were real, and widening detection
changed one accept on the way.

Gap 1 (nounplre boundary). bothre and the noun-lead rule keyed on nounplre,
a noun list, so the cohort, team and member mutants named in lexlead/pre.txt
failed to name a domain in their clause and coreferred with the checked set:
5 mutants accepted before the fix and refused after (lexlead/pre.txt,
lexlead/post.txt).

Gap 2 (modifier span). the noun-lead chain allowed at most two modifier words
before a noun in the list, so the four long-phrase mutants, carrying a
three-word or four-word noun phrase, passed the same way: 4 accepted before
and refused after (lexlead/expect.txt, lexlead/post.txt).

Flip on the way. one accept flipped: the verb-mid fixture where the quantifier
sits after the verb and takes an object was refused before the fix because
the residue read the object as predication of a bare pronoun. The
clause-subject rule reads only the pre-verb span, so that fixture accepts now,
and its sibling with a bare pronoun subject still corefers; the 4 anaphoric
fixture accepts stay accepted (lexlead/post.txt).

Fix. domain naming keys on shape instead of a noun list: a plural noun (s/es
ending or a short irregular list) preceded by an adjective-shaped modifier
chain, the bare quantifier both detected at clause-subject position, and a
restrictive relative clause with a listed verb read as a bound.

Residual named for the next pass. the lists stay lists: an adjective outside
the modifier shape before a plural noun, and a relative-clause verb outside
the short verb list, still read as unmodified or as coreference.

Corpus. scratch/lesson-derive-gate-2026-10-10/lexlead/ 21 fixtures, pre 10
gaps and post 0, and the sweep over 262 fixtures shows just the 6 intended
flips (lexlead/sweep-changes.txt). The corpus runner runs this corpus now
(lexlead/runall.txt), suite pass=189 fail=2, and the two reds are
pre-existing: the pre-patch binary refuses them too. pre binary
lexlead/lint.pre-lexleadfix.

Lesson (2026-10-10, overreach-lint lexlead): when a rule keys on a word list,
its failure class sits outside that list, so a fix that widens detection needs
the distinction that replaces the list to land at the same time. Here the
noun-list shape moved to clause-subject position plus an adjective-shaped
chain, and that is what kept the 4 anaphoric both accepts accepted while the
5 domain mutants refused.

evidence: file scratch/lesson-derive-gate-2026-10-10/lexlead/pre.txt
evidence: file scratch/lesson-derive-gate-2026-10-10/lexlead/sweep-changes.txt
evidence: contains scratch/lesson-derive-gate-2026-10-10/lexlead/verdict.txt pass=21 fail=0
evidence: contains scratch/lesson-derive-gate-2026-10-10/lexlead/runall.txt pass=189 fail=2
evidence: cmd test -z "$(grep -v probe-lexbound scratch/lesson-derive-gate-2026-10-10/lexlead/sweep-changes.txt | grep -E "^(accept|refuse)")"
evidence: contains bin/lesson-overreach-lint modshape='([a-z]+(ed|en)|new|old|fresh
