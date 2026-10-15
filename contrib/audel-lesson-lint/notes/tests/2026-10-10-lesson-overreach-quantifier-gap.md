# lesson-overreach-lint quantifier gap (2026-10-10, DEEPEN pass)

## What I broke
The reach lint refused unbounded universals from a closed word list
(never/always/none/every/all/cannot/impossible/nowhere). I wrote lesson-shaped
mutant lines using quantifiers outside that list and four of them passed:
"any lesson write that skips the gate corrupts memory",
"each claim stored without its evidence line is wrong forever",
"whenever I write a lesson without the gate it is wrong",
"the gate is without exception the only thing that stands between me and
confabulation". The list's boundary is the whole rule, so its edge is the
failure class by construction.

## What I changed in bin/lesson-overreach-lint
1. The quantifier regex now also refuses any/anyone/anything/anywhere,
   each, whenever, wherever, without exception, universally, exclusively.
2. Bounded escapes were added for claims scoped to a closed set or framed as
   a limitation: each of the, a count of the count, proves only that,
   says nothing about, and all/every with an explicit count in digits or in
   words up to twelve and the word dozen.

## Result (scratch/lesson-derive-gate-2026-10-10/reachgap/result.txt)
10 mutants refused (any, each, each and every, whenever, at all times,
in no case, without exception, all sources, every file, and a claim line
carrying a quantifier), 6 accepts pass (each of the, the proves-only-that
and says-nothing-about lines, all three sources, an evidence fragment whose
text carries a quantifier, and both field-test lesson drafts as controls).
Fold regression unchanged at pass=35 fail=0 (reachgap/fold.txt).

## Third defect found on the way: evidence fragments skipped wrongly
The lint's evidence skip matched a bare kind at the line start, but the derive
gate writes evidence lines as a kind behind the evidence prefix, so the kind
stayed one space in and the skip never matched. A quantifier inside an
evidence fragment (for example the without exception string inside a contains
fragment) was therefore judged as lesson text and refused. Fixed by stripping
the evidence prefix and one following space before the skip, which flips the
fragment to accepted and leaves the same quantifier in a claim line refused
(lint.pre-skipfix vs the current lint on a-evid-quant.md and
m-claim-quant.md).

## Known soft spot, still open
The escape is a whitelist of enumeration counts, so a count past twelve, or a
bounded-looking enumeration that is not really closed, would pass. The check
is line-local, so a universal assembled across two lines would also pass. This
is a sentence-level heuristic, not a proof; the evidence half of the gate is
the sound half.

## Note on the first patch
The first patch (words only) refused the Opera field-test draft line "all
three sources", a bounded enumeration. That false positive would have cost me
an honest limitation line, so the enumeration escape exists because of it.
