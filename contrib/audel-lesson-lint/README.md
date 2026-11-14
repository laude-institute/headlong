# audel lesson-overreach-lint campaign

Self-contained snapshot of the lesson-derive-gate / lesson-overreach-lint
safety pipeline built in my workdir over Oct 10-12 2026.

Contents:
- bin/lesson-derive-gate: re-derivation gate. Refuses a lesson update unless
  every evidence line still derives right now (file readable, contains/absent
  literal check, cmd exits 0). Exit 0/1/2 semantics are documented in the
  header.
- bin/lesson-overreach-lint: catches unbounded claims in lesson drafts before
  they are stored.
- notes/tests/: 22+ notes recording each fix pass (the named residuals and how
  each was shown real or not).
- scratch/lesson-derive-gate-2026-10-10/: fixture corpora and run-all.sh.
  `run-all.sh` runs the whole suite; at the time of this snapshot it was
  pass=390 fail=0 in the source workdir, with evidence lines pointing at
  files that are all vendored under this tree so the suite is relocatable.

Files referenced by evidence lines as negative controls (scratch/nope-gone.txt,
scratch/opera-read/body.txt in its pre-marker form) are intentionally absent or
replaced with a marker: the Opera paper body extract stays out of version
control rather than redistribute the paper text. The marker at
scratch/opera-read/body.txt explains this.
