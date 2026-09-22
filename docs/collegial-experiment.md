# Collegial coding: candidate integrity and a repeatable experiment

`coding-agent` runs a bounded OpenCode task against a committed Git base,
retains a candidate, and returns evidence through the trajectory DAG. A passing
candidate is never an automatic acceptance, merge, push, or deployment.

Install OpenCode separately and configure its provider credentials. The wrapper
uses the executable on PATH, or `--backend-bin`, and accepts `--model` (also
`CODING_AGENT_MODEL`). It forks the supplied parent trajectory, runs the executor
in a new candidate worktree, commits its edits, reruns the supplied check, and
records a result edge in the parent. A trajectory merge records lineage; it does
not merge Git changes. Without a parent, it creates a standalone trajectory.

## Candidate integrity

A result can be `candidate` only if execution, commit capture, and verification
succeed and the integrity checks pass:

- Subprocess exit codes are preserved, including 125. A deadline returns 124.
- The committed candidate worktree must be clean before verification.
- Verification must leave HEAD, branch, index entries, tracked file contents,
  modes and symlinks, and non-ignored untracked files unchanged.
- The source checkout must retain those same invariants throughout the run's
  before/after comparison. A pre-existing dirty source is allowed if it stays
  unchanged. A changed-and-committed source is not mistaken for unchanged.
- Snapshot errors fail closed. Results retain before/after fingerprints and
  integrity flags; evidence is retained even when a candidate is rejected.

New failure statuses are `verification_changed`, `source_changed`, and
`integrity_check_failed`. A nonzero verification exit remains
`verification_failed` even if the check also changed files; inspect
`verification_checkout_unchanged` for that additional condition. Source
integrity failures take precedence over executor/check failures; the original
exit statuses remain available in the result.

The check is intentionally limited to Git-visible files. Ignored runtime files
(such as `__pycache__`, dependencies and identity state) are excluded unless
tracked. Initialized submodules are fingerprinted recursively. Git hooks,
configuration, other refs and arbitrary files outside the checkout are not
protected. A before/after comparison cannot detect a temporary change that is
restored. These are integrity checks, not an adversarial OS sandbox; model
permissions are not a replacement for one. Concurrent legitimate source edits
will conservatively reject the candidate too.

Verification should be read-only for the candidate's source files. If it needs
to generate source, that generation belongs in the implementation before the
candidate commit. Put disposable caches in ignored locations or disable them.
Do not repair and auto-commit from the verifier: that would attest to a different
candidate. Acceptance tests outside the worktree reduce accidental test edits,
but local unsandboxed processes still have the user's filesystem privileges.

## Deadlines and artifacts

`--timeout SECONDS` (or `CODING_AGENT_TIMEOUT`) sets a positive integer deadline
for **each** executor and verification phase. The default is 300 seconds per
phase. On expiry the wrapper sends TERM, then KILL after a one-second grace
period, to that phase's process group, records exit 124, and returns a failure
through the normal trajectory path. Ordinary descendant processes are stopped;
a process deliberately detaching into another session can escape that group.
Git setup/commit operations and snapshot work are outside the phase deadlines.
A timeout is not a spending cap.

`--out` must be new or empty. Reusing an artifact directory is refused before
previous transcripts are overwritten. Place it outside the source checkout or
inside a Git-ignored directory. For a standalone run, the wrapper creates its
parent trajectory below that directory. JSON is printed to stdout; redirect it
to a separate file if desired, not a file inside `--out` before the command runs.

```bash
bin/coding-agent --repo /path/to/repo \
  --task 'A bounded change with explicit requirements' \
  --verify 'PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests' \
  --timeout 120 --out /tmp/new-candidate > /tmp/new-candidate-result.json
```

Dependencies are Bash 3.2+, Git, jq, Python 3, and Perl for log redaction (plus
OpenCode for live runs). Worktrees, branches, and transcripts are retained;
cleanup is manual. The wrapper has no spending cap or automatic retry policy.

## Reproduce rejection and revision without model calls

From the repository root:

```bash
python3 tests/experiments/collegial_slugify.py \
  --out /tmp/slugify-experiment-1
```

Choose a fresh output directory for each run. This creates a new Git fixture
from `tests/fixtures/collegial-slugify`, with a fresh trajectory and source
checkout for each run.

The experiment uses the real `coding-agent`, Git commits/worktrees, verification
commands, and trajectory fork/merge operations. Only executor implementations,
task selection, and review decisions are scripted. It spends no API money.

1. The first fixture executor makes a candidate that passes the deliberately
   weak basic check (`Hello World` becomes `hello-world`).
2. The external full checker tests whitespace, punctuation, repeated separators,
   digits, empty input, and separator-only input. It rejects that candidate.
3. The parent receives a rejection observation with concrete failing cases and
   the child/commit references.
4. A new delegation starts from the first candidate commit and receives that
   feedback. The second fixture executor implements the full behavior.
5. Full verification and review pass. The parent records `ready_for_human_review`
   and `revision_of`, but `accepted` remains false. No changes are integrated.

Inspect `summary.json`, `result-1.json`, `result-2.json`, `review-1.json`,
`review-2.json`, `task.md`, `trajectory-check.txt`, the trajectories, and the two
retained worktrees in the output directory. The summary explicitly records
`invocation: scripted_fixture`, `autonomous: false`, and `api_calls: 0`.

The shell-suite regression `tests/test_collegial_experiment.sh` checks the
outcomes and the parent rejection/revision references. `tests/test_coding_agent.sh`
separately covers exit codes, verification mutations, source integrity,
deadlines, ignored caches, no-op results, and evidence retention.

## The next live experiment

The monolith prompt now asks it to compare the diff with the actual requirements,
record a substantive rejection with feedback, and use the retained candidate
as the base of a later bounded revision. The scripted run proves the mechanism
and the evaluator, not Headlong's ability to follow those instructions. A live test must remain a separate measurement:

1. Prepare a fresh identity and a fresh copy of this fixture. Use the updated
   monolith prompt/tools so the run has its own clearly attributable history.
2. Set a small dedicated provider spending limit and the wrapper's phase
   deadlines; bound the supervisor's iterations and output tokens as well.
   An account-wide key limit is not a per-experiment cap.
3. Put the task into the identity's trajectory and let the real monolith decide
   and invoke delegation. Preserve its actual shellm run ID and command, not
   just fork/merge records produced by a manual driver.
4. Have the monolith inspect a mechanically passing but substantively inadequate
   proposal against the full requirements, record its reasons, and delegate a
   revision based on the retained candidate. An intentionally injected proposal
   must be labelled as such; do not force a successful executor to get it wrong.
5. Review the final diff, run the external full checker, and keep integration
   human-directed. Report whether task selection was prompted or self-initiated,
   who made each review decision, all failures, the actual spend, and whether
   any candidate was accepted.

A provider outage is an operational failure, not substantive disagreement. A
contradictory test is an evaluator defect, not a successful collaboration.
