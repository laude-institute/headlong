# overreach-lint relcl pass (2026-10-11): a bound needs a determiner and its
# own verb list, so both residuals the lexlead note named were real

Both residuals the lexlead comment named held in one shape each, and fixing
them needed a shape rule again, not a longer list.

Gap 1 (determiner). rcbre required the/that/these/those before the relative
subject, so "fixtures lint named" read as no bound and the clause refused a
bounded lesson (relcl/a-nodeterm-named.md, refused pre-fix, accepted after).

Gap 2 (verb list). rcbre's verbs were a hand list, so "we shipped", "the
pass refactored", "the sweep made" read as the clause predicate and the
universal went unbounded (relcl/a-verb-shipped.md, a-verb-refactored.md,
a-verb-made.md: refused pre-fix, accepted after).

Fix is relclause_ok, a shape test: a plural check noun with at least one
non-auxiliary word and then a past verb after it is a relative clause
restricting the noun to the ones named, while a past verb straight after the
noun ("all runs verified the output") is the clause predicate and bounds
nothing. Three re-break probes confirm the boundary (relcl/m-rebreak-*:
unlisted past verb, reduced passive relative, and a future modal all stay
refused).

Two bugs found on the way, both worth naming. First, the awk helper named a
variable sub, colliding with awk's builtin sub(), which is a syntax error, so
the helper silently matched nothing and every fixture looked unchanged on the
first post-fix run. Second, the shape test read the plural "times" inside the
quantifier phrase "at all times" as a domain noun and fired a false bound,
flipping reachgap/m-attimes from refuse to accept; the quantifier phrase is
now blanked before the shape test (a bound cannot come from the words of the
claim it bounds).

Suite scratch/lesson-derive-gate-2026-10-10/run-all.sh covers the relcl
corpus now (10 corpora), pass=200 fail=2, both reds pre-existing and refused
by the pre-patch binary. Evidence scratch/lesson-derive-gate-2026-10-10/relcl/
(pre.txt, post.txt, re-break probes, sweep-changes.txt), pre-patch binary
relcl/lint.pre-relclfix.

Residual named for the next pass: the verb list in relclause_ok is still
lexical, so a past verb outside it ("the sweep clipped") reads as no relative
verb, and a relative clause whose subject is itself a quantifier ("all
builds that every run named") is not read as a bound shape at all.

Lesson (2026-10-11, overreach-lint relcl): a derived rule must exclude the
words of the claim it is judging before it can read a shape in that claim, or
it finds its pattern inside the quantifier phrase itself and grants the claim
its own bound.

evidence: file scratch/lesson-derive-gate-2026-10-10/relcl/pre.txt
evidence: file scratch/lesson-derive-gate-2026-10-10/relcl/post.txt
evidence: contains scratch/lesson-derive-gate-2026-10-10/relcl/runall.txt pass=200 fail=2
evidence: contains bin/lesson-overreach-lint relclause_ok
evidence: cmd test "$(bin/lesson-overreach-lint scratch/lesson-derive-gate-2026-10-10/reachgap/m-attimes.md >/dev/null 2>&1; echo $?)" = 1
evidence: cmd test "$(bin/lesson-overreach-lint scratch/lesson-derive-gate-2026-10-10/relcl/a-nodeterm-named.md >/dev/null 2>&1; echo $?)" = 0
