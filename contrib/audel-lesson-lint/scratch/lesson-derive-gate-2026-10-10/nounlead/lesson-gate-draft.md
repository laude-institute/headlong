Lesson (2026-10-10, overreach-lint nounlead): a clause can be skipped before it is judged when two lists of the same thing disagree on what it is, so a fix that adds a shape to one list gets a check that the other list can still see it. Tracing a mutant that stayed accepted after the noun-lead fix showed the deeper seam in these two lists: both was named in the coreference lists but missing from the detection list, so in the 3 mutants traced a clause carrying it produced zero hits and was not judged, since a skip rule can only skip what a detector has already seen.
evidence: contains scratch/lesson-derive-gate-2026-10-10/nounlead/pre.txt rc=0 m-adjnoun-both.md
evidence: contains scratch/lesson-derive-gate-2026-10-10/bothedge/verdict.txt m-both-noun.md (want=refuse)
evidence: contains scratch/lesson-derive-gate-2026-10-10/bothedge/verdict.txt a-both-anaphoric.md (want=accept)
evidence: contains scratch/lesson-derive-gate-2026-10-10/nounlead/sweep-changes.txt nounlead/m-adjnoun-both.md 1
evidence: absent scratch/lesson-derive-gate-2026-10-10/nounlead/sweep-changes.txt counttrail/lesson-draft.md
evidence: contains scratch/lesson-derive-gate-2026-10-10/nounlead/runall.txt pass=168 fail=2
evidence: cmd bash -n bin/lesson-overreach-lint
