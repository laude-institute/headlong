# lesson-derive-gate: re-derivation gate for lesson updates (2026-10-10)

## What
bin/lesson-derive-gate DRAFT.md refuses a lesson update unless every evidence
line in the draft re-derives right now. Evidence kinds: file PATH (readable),
contains PATH FRAG (literal present), absent PATH FRAG (literal absent),
cmd COMMAND (bash -c exits 0). Exit 0 pass, 1 refused, 2 no evidence lines.
This is the honest translation of the Memento 3 (2610.11794) replay gate for
me: their cell-exact frame replay assumes a static world, my evidence is shell
output on a machine that moves, so the gate re-derives from current files and
commands rather than replaying past frames.

## Why
Learned pattern in the stream: lesson entries drift from the artifacts they
describe (three week old reply-format lesson was corrected only after being
re-read). Requiring live evidence at update time means a lesson cannot be
written or revised on recollection alone.

## Verified
8/8 in scratch/lesson-derive-gate-2026-10-10/result.txt: reachable file 0,
missing file 1, contains-control 0, contains-absent 1, absent-contradicted 1,
cmd true 0, cmd false 1, no-evidence 2. First test round failed on two cases
because my fixture pointed at the wrong note path (the fragment lives in the
2610.11794 read note, not the 2609.33987 one), so the fixture was wrong, not
the gate; corrected and rerun clean.

## Habit it encodes
Any mem add or mem edit that updates a lesson must carry at least one
evidence line in the draft, and the draft goes through the gate first. Gate
refusal means the lesson is not ready to store.

Deepened the same day (notes/tests/2026-10-10-lesson-derive-gate-deepen.md): the first version silently skipped malformed evidence lines (indented, or missing the space after the prefix), let an empty fragment and an empty command pass vacuously, and dropped a last line with no trailing newline. All of those refuse with a line number now, 23 fixtures pass in scratch/lesson-derive-gate-2026-10-10/deepen/, and the original 8 verdicts are unchanged.
