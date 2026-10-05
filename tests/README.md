# tests/

Test scripts for the harness. Each `test_*.sh` is a self-contained
executable, so run one directly, e.g. `tests/test_context.sh`.

`fixtures/` holds small trajectories the tests render, and `golden/`
holds the expected outputs. `tests/test_context.sh --regen` regenerates
the golden files from the current `bin/context` after an intentional
output change.

`run-all.sh` runs every `test_*.sh` in turn and summarizes (optionally
filtered by a name substring, e.g. `tests/run-all.sh recap`).
`smoke_install.sh` exercises `install.sh` in both of its modes (checkout
and `curl | bash`) inside throwaway HOME directories.

CI (`.github/workflows/ci.yml`) runs both of these on every push to main
and every pull request, alongside the pytest suites in `web/`, `slack/`,
and `telegram/`, the viewer tests/typecheck/build, `cargo check` for the TUI,
and shellcheck at warning level.

`test_contrib_opencode.sh` runs the optional package’s offline lifecycle, integrity, and scripted rejection/revision tests. See [package setup](../contrib/opencode/README.md).

`test_deploy_update.sh` uses Python 3 and local git repositories to reproduce
an upgrade from the historical pre-guard updater (fixture from `bbb1104`).
System commands and HTTP are stubbed; tests check pending/applied deployment
files, login/status warnings, disabled sandbox behavior and secret-free output.

`test_traj_redaction.sh` requires Python 3 and checks credential masking before
JSONL and blob writes, sanitizer failure, and context/recap replay. It also runs
real `shellm` traces with a scripted LLM in a temporary HOME; all credentials
are synthetic and no inference or network calls are made.

`test_responder_reply_guard.sh` exercises bounded model calls and reply parsing
against a scratch identity with a scripted backend. Standalone `<skills show ...>`
replies defer the original request to the mind and send a holding message;
quoted commands, examples and ordinary prose remain valid replies.
