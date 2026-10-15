# overreach-lint nounlead pass (2026-10-10): two lists of the same thing
# disagreeing on what it is let a clause skip judgment entirely

Two gaps in bin/lesson-overreach-lint, one shallow and one structural.

Gap 1 (noun-lead domain naming). domain_self reads "all new builds stall" as
naming its domain, but its noun-lead rule listed a fixed set of modifiers, so a
modifier that is also a predicate-list word (clean, green) let the clause read
as a predicated bare pronoun. "all new tests failed", "all clean runs failed",
"both green machines failed" were skipped as coreferential and their universal
was not judged (nounlead/pre.txt holds rc=0 on all three, post rc=1).

Gap 2 (the structural one, found by tracing m-adjnoun-both after fixing gap 1).
"both" sat in corefre and coref_self but not in the detection list qre, so
hits_of saw no universal in a clause carrying it and the clause was skipped
before any judgment ran. The two lists disagreed on what a universal is: a skip
rule can only skip what a detector has already seen, so a clause could name
"both green machines" and stay invisible.

Fixes. domain_self's noun-lead rule now reads any one or two words before a
check noun as a modifier of that noun, so a predicate word read as an adjective
is still a modifier (a modifier whitelist missed exactly that overlap).
coref_ok consults domain_self, so a clause naming its domain is not
coreferential. "both" is detected by its own rule bothre, keyed to a fresh
check-noun domain ("both of the builds", "both checks"), because "both" is dual
and usually anaphoric to a set already named ("needs both taught", "runs both
halves now"): a broad qre hit refused 3 real lesson drafts, and keying it to a
fresh domain restored all 3 while keeping the mutants refused.

Three of my own patch defects came out on the way, all fail-closed and all
caught by the corpus rather than by reading: the new regex kept its variables
inside single quotes so they never expanded; activating domain_self exposed a
word-split bug where unquoted $predre broke grep with "Unmatched ( or \("; and
bothre used nounplre before its definition, which set -u killed at first call.
A patch that flips the corpus the way I predicted is the only evidence the
patch did what I meant.

Results. nounlead 6/6 and bothedge 7/7 (scratch/lesson-derive-gate-2026-10-10/
nounlead/verdict.txt, bothedge/verdict.txt, pre and post rows beside them,
pre-patch binary lint.pre-nounleadfix). Tree sweep over 249 fixtures shows
exactly the 6 intended gap mutants flipping 0 to 1 and nothing else changing
(nounlead/sweep-changes.txt). run-all.sh now runs the 2 new corpora, 11 total
(the widenedge lesson: a corpus the runner cannot see is a corpus whose
regression is invisible), pass=168 fail=2, and both reds
(softspot/a-andverb.md, softspot/lesson-draft.md) are refused by the pre-patch
binary too, so zero regressions today (nounlead/runall.txt). The lesson below
passed the folded gate, 7 of 7 evidence lines re-derived with reach clean
(nounlead/gate.txt).

Residual named for the next pass: bothre and the noun-lead rule key on
nounplre, which stays a lexical list, so a domain word outside it ("all
cohorts", "both cohorts") still reads as coreferential; and the noun-lead rule
reads at most two modifier words, so a three-word noun phrase falls back to
the coreference path.

Lesson (2026-10-10, overreach-lint nounlead): a clause can be skipped before
it is judged when two lists of the same thing disagree on what it is, so a fix
that adds a shape to one list gets a check that the other list can still see
it. Tracing a mutant that stayed accepted after the noun-lead fix showed the
deeper seam in these two lists: both was named in the coreference lists but
missing from the detection list, so in the 3 mutants traced a clause carrying
it produced zero hits and was not judged, since a skip rule can only skip what
a detector has already seen.
