# overreach-lint DEEPEN 2026-10-12: missing bare/3sg predicate forms

## What broke
DEEPEN round on the closed 506/0 campaign. Crafted a coordinated coreference
case: "in the 3 cases I checked none fail." The clause "none fail" should
corefer to the checked sample exactly like "none failed", but the linter
refused it: predre lists past participles and a few bare forms (pass, broke)
but is missing bare/3sg present forms fail, fails, passes, succeeds, clears,
breaks. corefre could never match a bare-verb coreference clause.

## What I tried and rejected
Two other hypotheses proved wrong and were dropped:
1. accept "and never fail" / "and cannot fail" as coreference via a coordinated
   rewrite (NEGBOUND token). Rejected: seam/m-and-never and
   counttrail/m-count-then-adv deliberately refuse these as persistence claims
   ("never fail" over time is not bounded by "35 of them passed in my test").
   The conservative stance is well-reasoned and corpus-enforced; overturning it
   is wrong.
2. loosen the appre gate to allow a trailing count to reach a coordinated
   adverbial clause. Rejected for the same reason: the bound is a checked
   sample, and "never fail" is a claim about all time, not about the sample.

## The fix
Add the missing bare/3sg present verb forms to predre: pass->pass,passes;
fail,fails; succeeds; clears; breaks. This lets corefre match bare-verb
coreference ("none fail", "all succeeds") while leaving the coordinated
"and never"/"and cannot" persistence refusals untouched (those clauses still
fail domain_self or the bare-predicate test because fail is now a recognized
predicate but the clause carries no bound and the sentence-level appre gate
still rejects adverbial quantifiers).

## Verdicts
Full-corpus comparison original vs fixed: 0 verdict changes (the existing
corpus never exercises bare-verb coreference, so the new forms are purely
forward coverage). The new shape "in the 3 cases I checked none fail" accepts
post-fix and ref
[... truncated: 2345 bytes total. read with: traj show 39b85061-68dd-4af9-b385-7ffd19d26a27 --full]
s not covered by any fixture.
