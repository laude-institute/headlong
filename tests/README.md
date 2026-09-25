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
