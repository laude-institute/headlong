# Local decisions in Headlong — 2026-10-09

Custos has two independent inference paths:

- Generative work: the existing Johan → OpenRouter Haiku gateway, unchanged.
- Typed decisions: `decide` → operator broker in LXC 131 on 18085 → Tycho Snap1-2B
  Q8, with TypeSafe Jev as the authorized fallback. The old standalone Jev skill
  is retired by the operator; its credential broker is retained for this fallback.

The release adds an explicit tool and three **observation-only** hooks. Context
checks run at shellm iteration 1 and every eighth iteration. Progress checks run
every fourth iteration. Response checks cover shellm final reports and validated,
nonempty responder reply plans. They do not cover every arbitrary direct action
or intermediate chat send. Hooks have no authority to alter the original model
context, memories, goals, commands, send decisions or receipts. They return no
assessment into the reasoning trajectory. Compaction, automatic blocking and
semantic control of routing remain future experiments.

## Configuration and audit

Operator file `/etc/headlong-decisions.json` in CT122:

```json
{
  "enabled": true,
  "mode": "shadow",
  "shadow_hooks": ["context", "progress", "response"],
  "endpoint": "http://192.168.86.69:18085/evaluate"
}
```

`HEADLONG_DECISIONS_CONFIG` can select a disposable test configuration. Production
has no override. Only shadow mode is implemented. With no file or `enabled:false`,
the hooks and explicit tool make no provider calls. Remove an individual hook from
the list to disable it while retaining the tool and the other observations.

Audit records are under the persistent identity's `run/logs/decisions/`, directory
0700 and files 0600; up to four approximately 8-MiB segments. Records contain actual
provider/model, rubric hash/version, evidence hash, bounded redacted packet,
latency, outcome and `applied:false`. They are private operator evaluation data.
An audit lock/disk failure warns but cannot change the original reasoning or reply.
Raw trajectory and memory are untouched. This is an operator trace, not a new
dashboard panel or an assertion of progress savings.

Packets retain source indices and explicit excerpt/omission markers. The model
has 8K context; oversized inputs are rejected and observations become unavailable.
The context hook offers one skill shortlist suggestion from at most 20 candidates
plus an evidence-block suggestion. It does not hide other skills. Skill bodies and
executable skill blocks are never evaluated to construct the candidate catalog.

The whole hook inference operation has a 2.25-second deadline, with primary and
fallback socket budgets of one second each. The responder subprocess has a final
three-second guard. Explicit tool calls permit 29 seconds. No automatic retry.
The broker permits two calls, returns busy promptly on saturation, caps 240 calls
per minute, and skips Tycho for 30 seconds after three failures. Jev retains its
own one-active-call/60-per-minute limits; errors leave existing reasoning in charge.
Input errors (HTTP 400/422) do not fall through to Jev. The broker uses a fixed
local Tycho destination and the existing loopback Jev broker, without credentials.

Hal explicitly requested Jev as Tycho fallback. The same bounded evidence may
therefore leave the homelab during failover. Snap results identify its configured
pinned deployment artifact. Jev reports `jev-latest`, no local artifact hash, and
unknown provider truncation (its existing broker does not expose that metadata).
Neither distribution is a calibrated probability of correctness.

## Initial qualification

27 new offline tests cover typed schemas, exact answer matching, invalid input,
provider failover, circuit recovery, concurrency, bounds, private logging, and a
real shellm loop with a failing helper that cannot inject context or change its
answer. 123 affected existing tests passed. Full supervisor qualification is
recorded with the release's request receipt.

The frozen 100-case corpus is `tests/fixtures/decision_eval.json`: 36 context,
32 progress and 32 response cases. These are synthetic and incident-derived with
related variants; they are not 100 independent real-world episodes. Snap scored
35/36, 27/32 and 28/32 respectively, with no HTTP failures or cloud fallback. Median
broker round trips were 76.92, 48.08 and 77.56 ms. The progress errors included
useful diagnosis misclassified as repetition. Grounding errors confused missing
evidence with contradictory evidence. No hook is qualified to control behavior.

Real synthetic provider checks passed through the production Snap broker and,
with an isolated injected Tycho outage, the real Jev fallback. No GPU service was
stopped for that test. Snapshot reports retain the full results and failed cases.

## Deployment and rollback

Build/qualify/deploy the exact committed guest artifact through `custos-harness`.
The operator separately installs the CT131 service, contract module and narrow
18085 firewall allowance. All new service code runs inside CT131. Existing Jev,
generative admission, host supervisor and GPU services are preserved.

Rollback guest code through the supervisor, retaining identity and receipts.
Set `enabled:false` first to disable all decision use immediately; there is no
reason to restart the generative gateway. The broker and its dedicated firewall
allowance can be removed separately. The retired Jev skill is retained in the
operator backup directory outside the skill catalog, if an explicit reversal is
desired. Never restore an old complete firewall file over intervening changes.
