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

`experiments/collegial_slugify.py --out /tmp/fresh-slugify-run` retains an offline
delegation, semantic rejection, and revision experiment. It uses real worktrees
and trajectories with fake executors; it makes no autonomous claim and no API
calls. See [the experiment guide](../docs/collegial-experiment.md).
