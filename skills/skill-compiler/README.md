# Skill validator reference

Use this when developing a skill or checking its documented behavior. It calls
`llm` to propose cases, runs each through `shellm`, and saves results. It does
not train an adapter, alter the skill, or add examples to `skills show`.

## Requirements and invocation

Requires Bash, Python 3, jq, and the existing `llm`, `shellm`, and `skills`
commands. Model calls use your normal llm configuration and can incur charges.
`--teacher-model` overrides only the teacher model; otherwise llm resolves its
model and provider normally, including `SHELLM_MODEL` and `LLM_PROVIDER`.

The installer copies this directory but does not add its executable to PATH.
For a standard installation:

```bash
sc="$HOME/.skills/core-skills/skill-compiler/skill-compiler"
"$sc" compile --skill shellm --num-tests 3 --max-iterations 5
"$sc" pool --skill shellm
"$sc" list
"$sc" show --skill shellm
"$sc" clean --skill shellm
```

From a source checkout, use `sc="$PWD/skills/skill-compiler/skill-compiler"`.
`SKILLS_DIR` defaults to the directory containing this skill;
`SKILLS_KERNEL_DIR` selects a second search root. An existing `SKILLS_DIR`
setting takes precedence. `--num-tests` is a ceiling on cases executed (default
8); fewer returned cases are accepted and reported, and excess cases are dropped.
It and `--max-iterations` (default 15) require positive decimal integers within
the signed 64-bit range used by Bash.
Missing option values are rejected before any model call.

The teacher uses the normal llm loader in the original working directory. Before
isolating each runner, the validator resolves model/provider settings from the
original environment, cwd `.env`, then `${SHELLM_CONF_DIR:-<state-home>}/.env`,
using shellm's precedence. Explicit exports win even when empty; endpoint aliases
retain their process precedence. Only provider keys, model, endpoint, adapter,
routing, retry, and generation/context controls are forwarded from files. Live
state pointers and unrelated settings are not imported, and `.env` is never
copied into the workdir. Existing process exports remain inherited except the
state and identity selectors that isolation redirects.

Only run trusted skills. Both `compile` and `pool` can execute a skill script
with no arguments and with `--help`, in scratch with a 15-second deadline.
Remaining probe process-group members are killed on normal exit and timeout.
Both probes and tests use separate work, state-home, memory and trajectory
directories and clear caller identity/run selectors. This is not an OS
sandbox and does not revoke inherited credentials or other filesystem access.
The fixed refusal list excludes known messaging, credential and live-store
skills, including Obsidian. It rejects path spellings and aliases that bypass those names; installed
directory symlinks must retain the name, and files must remain inside the
resolved skill directory. This does not detect equivalent behavior in arbitrary
new skill code. Use an isolated environment for skills with side effects.

## Results and limits

Reports live in `<state-home>/skill-compiler/compiled`, independently of skill
reinstallation. State home follows `HEADLONG_HOME`, then `SHELLM_HOME`, then
`~/.headlong` (or existing `~/.shellm` if `~/.headlong` is absent).
`SKILL_COMPILED_DIR` overrides the report directory.

Each skill has a Markdown summary, JSON results, a `.json.prov` provenance
sidecar, and `pool-<skill>.json` containing offered and dropped vocabulary.
`clean` removes all four. Invocation scratch and completed test runs are removed
on exit. Set `SC_KEEP_RUNS=1` to retain them for debugging; their location is
printed to stderr. `SC_TMP_BASE` and `SC_RUNS_BASE` override scratch locations.

Every expectation requires shellm to exit successfully and evidence from the
actual launched root run. A nested run's answer or another run's rows cannot
satisfy a case. `final` requires a nonempty final answer. `observation` and
`shell-output` require nonempty content of their named type; they do not also
require a final answer. `error` requires a shell-output record with a nonzero
command `exit` value (excluding execution timeouts) anywhere in that root run.
This coarse condition can be met by an incidental failed command; it does not
establish that the skill rejected the intended input. Review the generated case
and prefer a diagnostic literal relevant to that operation. Without literals a
passing case is only `GREEN-NO-LITERALS`. A provider failure, stall, or generic error record is not
an expected skill error. All requested literals must also match recorded output
or the root final answer. Documented output remains eligible when actually
recorded; task and command echoes are excluded. Arbitrary workdir files are not evidence.

Matching is case-insensitive for both words and phrases. Words match whole
words with optional s/es plurals; phrases match substrings with digit boundaries.
Quote-style folding and denial/echo exclusions still apply. Provenance labels
compare the original literal spelling with the offered vocabulary.

Setup, runner, or root-selection failure records `harness_error`, retains prior
results, and returns nonzero. JSON results retain the runner exit code and up to
2,000 bytes of stderr for diagnosis. Ordinary failed assertions are recorded in
the report; compile can still exit zero, so inspect `summary.fail`.
`expect_contains_missed` contains checked but absent assertions;
`expect_contains_unchecked` contains assertions skipped because the runner or
required outcome failed. Neither skipped assertions nor absent literals pass.

Literal labels are `POOL-EXACT`, `POOL-FRAGMENT`, `POOL-DROPPED` (eligible
vocabulary omitted by a cap), or `INVENTED` (not found in the collected pool).
Only passes with at least one literal and exclusively exact/fragment labels
are `VERIFIED`. Other statuses are `GREEN-ON-DROPPED`, `GREEN-ON-INVENTED`,
`GREEN-NO-LITERALS`, and `FAIL`. Counts are separate in the JSON summary.

VERIFIED means vocabulary attestation, not meaningful behavioral coverage.
Short or common phrases can be weak assertions. Review generated cases and
include negative cases that should fail. No literal length proves test quality.
`literal_sources` distinguishes actual captured `TOOL-OUTPUT` from script text,
documentation, metadata, and unattested strings. Static text alone does not
prove that a tool emitted it.

## Pool controls

`SKILL_POOL_SRC_CAP` (200 per static source), `SKILL_POOL_LIVE_CAP` (80),
`SKILL_HARVEST_MAX_ENTRIES` (300), and `SKILL_POOL_CAP` (400 combined) limit
offered vocabulary while retaining eligible omitted entries for provenance.
Each cap must be a nonnegative decimal integer; surrounding whitespace is
accepted, and zero offers no entries from that source. Invalid settings name
the offending variable. Stable deduplication preserves source priority: script,
live output, history, then documentation. History entries rank by descending
count before their source cap; explicit string arrays keep their input order.
`SKILL_HARVEST_MIN_COUNT` (default 2) requires a positive decimal integer and
selects the minimum observation count for a historical line (within the same
signed 64-bit range). Invalid values
fail with the setting's name, rather than silently dropping history.
History is a sample of up to 300 matching trajectory files, not exhaustive output.
`SKILL_AUTO_HARVEST=0` disables history reads; otherwise it uses
`SKILL_HARVEST_TRAJ_DIR`, `TRAJ_DIR`, or `<state-home>/trajectories`.
`SKILL_HISTORY_POOL` supplies captured history explicitly, and
`SKILL_REAL_OUTPUT` supplies output for source classification. History JSON uses
`entries[].line`; metadata fields are never treated as output.

History caches live under `<state-home>/skill-compiler/history`, overridden by
`SKILL_HARVEST_CACHE`. TTL is `SKILL_HARVEST_TTL` seconds (3600);
`SKILL_HARVEST_REFRESH=1` rebuilds. `SKILL_HARVEST_ECHO_FILTER=music` optionally
filters note/interval echoes; it is off for general skills.

Generated tests contain `name`, `prompt`, `expect` (`final`, `observation`,
`shell-output`, or `error`), and optional `expect_contains` strings.
