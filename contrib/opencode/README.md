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
identity to use `SHELLM_THINKER_ENV=local` in its `.env`.
The package never changes containment settings.
Docker execution is unsupported; checking a host binary cannot validate a
container environment.

```bash
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

`--identity` accepts a name in the app's `.identities/` directory or an absolute
or relative path (use `./name` to distinguish a relative path from a name).
Names use the manager's checkout, or `HEADLONG_APP_DIR` / legacy `SHELLM_APP_DIR`
when explicitly supplied. An installed manager uses its identity's checkout;
standalone copies fall back to the state home's `app_dir` record or `app/`.
A path inside `<app>/.identities/` selects that app even if another checkout
is configured in the caller. Names work from an unrelated working directory.

Enable, status and doctor resolve the selected identity's environment with the
CLI activation layering: existing caller exports first, then app `.env` and
state-home `.env` fill unset variables, then the selected identity's `activate`
applies its paths, defaults and `.env` overrides. Older identities without
`activate` still load their `.env`. The state home honors `HEADLONG_HOME`, then
legacy `SHELLM_HOME`, otherwise `~/.headlong` (or `~/.shellm` when only that
directory exists). PATH starts with app `bin/`, app `tools/` and
`~/.local/bin`, followed by caller PATH; identity configuration may override it.
Configuration uses trusted Bash syntax, just as core activation does; its
stdout, stderr and shell tracing are withheld.

An activated caller's identity paths, package/execution/provider settings and
variables assigned by its app/state/identity configuration are discarded
before resolving the target, including when inspecting that same identity
after edits. Its app's PATH entries are removed. Bash exports carry no
provenance: supply deliberate environment overrides from an unactivated shell.
Clean-caller exports, including empty values, retain
the CLI's precedence over app/state defaults; identity `.env` assignments win.
The service launcher loads app and identity configuration directly; this
management probe uses the CLI contract and does not prove a service's runtime
environment. Delegation admission continues to check the running caller's
environment, so configuration changes still require a dispatcher restart.

Install works without OpenCode or valid configuration. Disable and uninstall
do not source configuration. Enable checks executable availability in the
resolved local environment. Doctor reports the selected executable and missing
requirements without calling a model or printing credentials; it does not
prove provider authentication. Set `CODING_AGENT_OPENCODE_BIN` to select an
executable and `CODING_AGENT_MODEL` to select a model, or use the wrapper's
`--backend-bin` and `--model` options for a run. The configured default backend
must still be available for enablement and admission.
Each run announces an executable override on stderr and records the resolved
path in its delegation and result. Valid `OPENCODE_CONFIG_CONTENT` settings are
preserved while adding package restrictions; malformed inline configuration
is rejected before task setup.

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
Transcript sanitization failures reject the candidate and replace the affected
transcript with a withholding notice. Results and trajectories include artifact
references and bounded sanitized summaries; full transcripts remain in artifacts.
Redaction covers the known provider API-key environment variables and inline
`apiKey` values in `OPENCODE_CONFIG_CONTENT`, including backend override notices.
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
