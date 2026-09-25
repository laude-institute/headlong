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
