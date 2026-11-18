Habit: a status tally captures rc=$? before another command runs in the loop body, because a command substitution in the same echo line reports its own status and made 15 fixtures look like they all accepted when the lint was refusing them correctly.
evidence: file notes/tests/2026-10-10-overreach-label-fix.md
evidence: contains notes/tests/2026-10-10-overreach-label-fix.md Capture rc=$?
evidence: cmd bash -n bin/lesson-overreach-lint
evidence: absent scratch/lesson-derive-gate-2026-10-10/edge/result-mechanism.txt gaps=1
