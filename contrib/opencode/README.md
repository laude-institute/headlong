# Optional OpenCode coding delegation

This package is an opt-in experiment. A default Headlong install has no
OpenCode dependency, wrapper, or delegation instructions. Installation copies
this package into one existing identity, disabled; enablement registers its
skill for that identity only. No global command, dependency installer, generic
extension manager, or default prompt change is involved.

## Local setup and lifecycle

Use a dedicated local test identity created by Headlong. This initial package
supports local execution only, with Python 3.8+, Bash 3.2+, Git, jq, Perl, and
Headlong's `traj` on PATH. Install OpenCode separately using its
[CLI documentation](https://opencode.ai/docs/cli/). Configure the dedicated
identity to use `SHELLM_THINKER_ENV=local` and export that setting in the shell
where you run these commands. The package never changes containment settings.
Docker execution is unsupported; checking a host binary cannot validate a
container environment.

```bash
export SHELLM_THINKER_ENV=local
identity_dir=/absolute/path/to/existing-test-identity
contrib/opencode/bin/headlong-opencode install --identity "$identity_dir"
manager="$identity_dir/extensions/opencode/bin/headlong-opencode"
"$manager" status --identity "$identity_dir"
"$manager" doctor --identity "$identity_dir"
"$manager" enable --identity "$identity_dir"
# Later:
"$manager" disable --identity "$identity_dir"
"$manager" uninstall --identity "$identity_dir"
```

Install works without OpenCode. Enable checks executable availability in the
current local environment. Doctor reports the selected executable and missing
requirements without calling a model or printing credentials; it does not
prove provider authentication. Set `CODING_AGENT_OPENCODE_BIN` to select an
executable and `CODING_AGENT_MODEL` to select a model, or use the wrapper's
`--backend-bin` and `--model` options for a run. The configured default backend
must still be available for enablement and admission.

Use OpenCode's provider authentication store or the selected provider's
API-key environment variable (for example `OPENROUTER_API_KEY`); all providers'
keys are not required. Run in the same user environment as the identity. Keep
credentials out of arguments and task text. Set provider-side spending limits
before any live experiment: a timeout is not a spending cap. No lifecycle
command makes paid calls. A live smoke run requires explicit operator spending
authorization; no live provider run is claimed by the offline test suite.

The wrapper uses OpenCode `--pure run --format json`, transporting the prompt
through stdin. Linux offline coverage uses scripted backends; CI also exercises
stock macOS Bash 3.2. OpenCode 1.18.30 CLI flags were checked on Linux ARM64;
this is not a live provider smoke test. Real OpenCode version/platform compatibility must be
recorded with any live smoke run, alongside the installed VERSION, exact
command, and result. See [the experiment](docs/experiment.md) for the retained
scripted rejection/revision evidence.

## Admission, evidence, and removal

The installed wrapper is private to
`$IDENTITY_DIR/extensions/opencode/bin/coding-agent`. It derives activation
from its own installation and checks it on every call. Skill discovery changes
on the next prompt assembly; a previously assembled prompt does not bypass
admission. Enable/disable are idempotent. Installation refuses to overwrite an
existing package or unrelated skill. VERSION records a digest of the copied
package contents, so later checkout changes do not alter the installation.

Disable stops new calls, removes skill discovery, and allows admitted runs to
finish. Uninstall first disables, then refuses removal while a run is active;
retry after it finishes. Stable lock files in `extensions/` are intentionally
retained to serialize later installations safely. Disable and uninstall work
without OpenCode. Neither operation deletes provider credentials, trajectories,
Git branches, worktrees, transcripts, or patches.

`--out` must be a new/empty directory outside the installed package. By default
artifacts are retained in a `headlong-coding-agent.*` temporary directory; choose
an explicit durable output directory for evidence you need to keep. Trajectories
use TRAJ_DIR/TRAJ_ID, or a standalone parent under the output directory. Output
and trajectory paths inside the package (including symlink aliases) are rejected.
To clean up evidence manually after review, remove its Git worktree with
`git -C SOURCE worktree remove WORKTREE`, delete the candidate branch if no
longer needed, and then remove the artifact directory. Review trajectory
references before deleting their targets.

Passing verification yields only a candidate with `accepted:false`. The wrapper
does not merge, push, deploy, or accept. Integrity checks cover Git-visible
checkout content, not remote side effects or the entire shared ref namespace;
a backend push can escape that check. Worktrees and model permission rules are
not an OS sandbox. Ordinary process-group descendants are terminated after
success and timeout before evidence is evaluated; deliberately detached sessions
are outside that mechanism. Disable is an operational control, not a security
boundary against an agent able to rewrite its own files or invoke OpenCode itself.

## Offline validation

From the Headlong checkout, run `contrib/opencode/tests/run.sh`. Tests install
isolated package copies and use scripted executors without credentials or paid
calls. Core tests invoke this runner explicitly, including on macOS. See the
[packaging validation record](docs/validation.md) for results and known base-test
failures.
