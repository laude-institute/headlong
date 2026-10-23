Lesson (2026-10-10, folded lesson gate): a link check on its own does not see overreach. Re-deriving each evidence line proves only that the link from rule to interactions is intact; a draft can still state a universal from a bounded sample, which is the failure the reach lint was built against. So a lesson write runs both halves now: evidence re-derivation and a reach lint that refuses unbounded universal quantifiers unless the line is bounded to what was checked or declared a norm with a rule: or habit: prefix. The two live in one command (bin/lesson-derive-gate calls bin/lesson-overreach-lint and fails closed if it is missing), with the fold suite green at 35 of 35.
rule: a check that validates one property says nothing about the properties it does not look at; run the second check before treating a gate as complete.
evidence: file notes/tests/2026-10-10-lesson-derive-gate-overreach.md
evidence: file notes/tests/2026-10-10-lesson-derive-gate-fold.md
evidence: contains scratch/lesson-derive-gate-2026-10-10/fold/result.txt pass=35
evidence: contains bin/lesson-derive-gate lesson-overreach-lint
evidence: cmd test -x bin/lesson-overreach-lint
evidence: cmd bash bin/lesson-overreach-lint scratch/lesson-derive-gate-2026-10-10/fieldtest2/draft.md
