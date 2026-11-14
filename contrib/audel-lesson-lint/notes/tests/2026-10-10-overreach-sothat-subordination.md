# Overreach lint: "so that" subordination (2026-10-10)

The residual named in the barewidening pass ("the split does not treat
"so that" as a subordinator") was real, and the comment the previous pass left
in bin/lesson-overreach-lint about a shielded clause naming its own domain is
stale: probe-domainself.md ("in the 3 cases checked the gate refused and every
run failed") is refused today by domain_self, so nothing there needed fixing.

What the sothat corpus (scratch/lesson-derive-gate-2026-10-10/sothat/, 13
fixtures plus one probe) found: "so that" and "so as" were split by the clause
splitter but left a stray "that" or "as" word at the front of the purpose
clause. The coreference rule reads a bare pronoun only at the clause start
(after an optional coordinator), so "in the 6 fixtures checked the gate held so
that nothing broke" was judged as a clause beginning with "that nothing broke",
matched no coreference rule, and was refused even though the sibling clause
carried the bound. Two bounded accepts were refused this way before the fix.

Fix: rewrite "so that" and "so as" to "and" before the clause split (keeping
"so far" swapped out and restored first), so a purpose clause is judged like
any coordinated clause. A bound sitting after "so that" still bounds the
purpose clause only ("the gate held so that in the 3 cases checked nothing
broke" accepts), and a bound in the main clause does not reach it ("every draft
is refused so that in the 3 cases checked nothing leaks" is refused).

Pre: 2 gaps (a-sothat-coref-none, a-sothat-coref-all refused). Post: 13 of 13
match expectations (sothat/post.txt). Regression: 196 fixtures under
scratch/lesson-derive-gate-2026-10-10 judged with lint.pre-sothatfix and the
new binary, regress-changes.txt lists exactly the two intended flips inside the
new corpus and nothing else. run-all.sh pass=54 fail=0 plus the fold harness 35
recorded. Pre-patch binary saved as sothat/lint.pre-sothatfix.

Residuals left: the widen word list is still a list, coref_verbs is a hand
list, the bare-scope test is a filler-word strip, a trailing count does not
reach a coordinated adverbial clause, and "so as to" is not handled.
