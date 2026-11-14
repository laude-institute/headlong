Lesson (2026-10-11, overreach-lint relcl): a derived rule must blank the quantifier phrase before it reads a shape in the claim it judges, or the shape lands inside that phrase and the claim grants itself its own bound.
evidence: file scratch/lesson-derive-gate-2026-10-10/relcl/pre.txt
evidence: file scratch/lesson-derive-gate-2026-10-10/relcl/post.txt
evidence: contains scratch/lesson-derive-gate-2026-10-10/relcl/runall.txt pass=200 fail=2
evidence: contains bin/lesson-overreach-lint relclause_ok
evidence: cmd test "$(bin/lesson-overreach-lint scratch/lesson-derive-gate-2026-10-10/reachgap/m-attimes.md >/dev/null 2>&1; echo $?)" = 1
evidence: cmd test "$(bin/lesson-overreach-lint scratch/lesson-derive-gate-2026-10-10/relcl/a-nodeterm-named.md >/dev/null 2>&1; echo $?)" = 0
