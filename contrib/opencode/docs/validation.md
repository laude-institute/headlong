# Review fixes validation (2026-09-26)

This pass starts from PR head `602d9166` and addresses the maintainer's remaining
review requests within the optional package. On Linux ARM64, the package suite
passes all 231 coding-agent assertions, the scripted rejection/revision
experiment, and lifecycle checks under both Bash 5.2.21 and Bash 3.2.57.
Bash 3.2.57 was built locally and placed first on PATH so the installed wrapper
and its subprocesses also used it. All seven package shell files pass ShellCheck
at warning severity and Bash 3.2 syntax checks; `git diff --check` is clean.

[Native macOS CI](https://github.com/laude-institute/headlong/actions/runs/36252719406/job/108433643487)
at `0c10540` exposed two failures in the credential-in-path
regression: its expected path used `/var/...` while the wrapper correctly
recorded `/private/var/...`. The expectation now retains the resolved parent
directory. A Linux reproduction using Bash 3.2 and a symlinked `TMPDIR`
confirmed the path mismatch before this test correction.
After correction, the complete package suite passes with that same symlinked
`TMPDIR`: 231 assertions, the rejection/revision experiment, and lifecycle
checks. ShellCheck and Bash 3.2 syntax checks also pass.

The added regressions exercise the installed public wrapper:

- Sanitizer failure on each executor/verifier stream and on every pass, including
  partial raw output, returns a failure and never a candidate. The synthetic key
  is absent from returned results, trajectories, and published transcript files.
  Full output stays in sanitized artifacts; trajectory excerpts are bounded.
- Backend-captured inline configuration preserves caller model, provider URL,
  credentials, and permission rules while adding package restrictions. Unset
  configuration receives defaults; malformed, empty, and non-object values fail
  before backend invocation without echoing credentials.
- With `core.fileMode=false`, both executable-only changes and executable changes
  alongside added files are committed correctly. Each exact candidate verifies
  in a fresh detached worktree. A post-commit hook mode mismatch is rejected.
- Rejected output paths leave no task file or new directory, preserve existing
  content and source status, and respect symlink resolution. Temporary default
  directories inside a non-ignored source path are removed on rejection.
- Default, environment, and explicit backend selection record the resolved
  executable. Overrides announce themselves; notices and records redact a
  synthetic credential even when it appears in the executable's filename.

The earlier complete core-suite and native macOS results remain historical.
No live provider calls or Docker integration runs were made for this review pass.

# Optional packaging validation (2026-09-25)

Validation ran on Linux ARM64, from PR head `95551e9` plus the optional-package
revision. A separate normal clone combined that revision with upstream
`7b528b349e9525cf4e0bacfd2648313b56d94eb7` using Git's merge tree. The merge was
conflict-free. No provider calls or paid smoke run were performed.

- `contrib/opencode/tests/run.sh` passed on both trees: all 108 original
  coding-agent assertions, the scripted rejection/revision experiment, and the
  new lifecycle regressions.
- Lifecycle coverage includes installed-but-disabled admission, per-identity
  skill discovery, missing prerequisites, idempotence, unrelated registrations,
  failed activation cleanup, symlink artifact paths, unsupported runtime,
  disable during a run, uninstall while active, re-enable, removal, and retained
  candidate/evidence history.
- A task over 280 KiB reached executor stdin and remained complete (including
  trailing newline) in delegation and result trajectory records. Successful
  executor and verifier background children were stopped before later writes;
  original timeout and integrity coverage remains intact.
- Package ShellCheck at warning severity, Bash syntax, and skill validation
  passed. CI includes the package's tests and Bash 3.2 syntax checks on macOS;
  native macOS execution was not performed in this local session.
- Core size is 11,048 lines on the PR tree and 11,298 on the combined tree,
  measured using the CI `cloc --quiet --json bin/ thinkers/` command. Both fit
  the restored 11,500-line cap.
- The PR tree's complete shell suite passed 86 of 88 scripts.
  `test_identity_export_import.sh` intermittently fails three soul-import
  assertions; the identical failures were reproduced on unchanged base
  `d64c6cb`, and the test also passed when rerun on this PR tree.
  `test_workspace_runtime.sh` assumes `.git/HEAD` exists as a regular path,
  which fails in this linked worktree.
- The combined tree passed 89 of 90 scripts. Its only failure was the same
  base-reproduced identity-import issue; the runtime test passed in the normal
  clone. The final package suite was also rerun successfully on that tree.

The PR's earlier `test_monolith_wake_sections.sh` fixture correction is retained
independently of packaging: its expected retrieval thought must occur among the
latest three stream entries, after the outbound-message fixtures. This corrects
the test setup without changing monolith behavior.

OpenCode 1.18.30's CLI flags were checked locally. Its CLI implementation reads
piped input (`Bun.stdin.text()`); the wrapper now supplies the prompt through
stdin instead of an argument. This does not establish live provider/model
compatibility. A live smoke run still needs explicit operator spending
authorization and the version, installed package digest, command, and retained
result recorded alongside its evidence.
