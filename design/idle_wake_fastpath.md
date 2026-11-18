# Idle wake fast path

The monolith can skip the model on an unchanged scheduled wake after a
successful turn with no durable work. Default on; set
`MONOLITH_IDLE_FASTPATH=0` to restore the previous behavior. No running
services need changing to test this feature.

This is deliberately narrower than "identical prompt". The clock and
execution scaffolding change every wake. The fingerprint includes the last
non-scaffolding record in the bounded raw trajectory tail (including inbound
messages, durable work and delivery events), runtime revision/sync line,
scheduled-goal signals without the current-clock line, relevant routing
configuration, memory and skill markdown contents, identity prompt and the
step/common/signature implementation. It is captured BEFORE a full turn,
so changes made during that turn invalidate the next wake.

A full turn is forced on cold start, reactive or manual triggers, pending
requests, due scheduled goals, goal-review/share nudges, fingerprint/cache
read errors, clock regression, prior model failure, and after thought or
visible work. Unknown trajectory record types conservatively invalidate.
Only known scaffolding (including final summaries) and idle/timer records
are ignored. A failure reading pending requests prevents both skipping and
idle eligibility on that full turn.

The cache is written atomically in the identity's run directory. Skips
append an idle record with `model_skipped:true` and
`reason:unchanged-wake-signature`; they never invoke shellm and never alter
the full-turn timestamp. They retain the existing backoff ladder. The next
timer is clamped to the last full-turn START plus 900 seconds, even with a
larger custom backoff cap. A wake at or beyond 900 seconds always runs fully.
This is a scheduling bound, not a promise to preempt an already running
model, repair a dead dispatcher or eliminate dispatch latency.

The floor matters: signatures cannot represent an autonomous thought that
has not happened yet. Work may be delayed up to the floor plus dispatch
latency. Files outside the fingerprint, child-only records, arbitrary
environment changes and external systems may also go unnoticed until that
turn; this is not a proof of prompt-input equivalence. Preserve the floor
when adding inputs. A corrupted raw-tail row fails open rather than being
silently discarded.

## Historical replay, not a production savings claim

An earlier 84-hour Harris trace contained 2,108 driver wakes, 359 labelled
productive and 1,749 idle. The original proposed signature kept 657 turns
and skipped 1,451 (68.8%), hypothetically skipping 85 productive wakes.
Adding a 15-minute forced turn kept 770 and skipped 1,338 (63.5%), with 82
productive wakes hypothetically delayed. These are model-TURN counts,
not API-call counts or measured dollar savings. A single turn can use
multiple calls.

The original signature used runtime, inbound high-water, due routing
signals and last non-idle mind step. This implementation is stricter
(pending-work bypass, prior-output eligibility, content changes and nudges).
The replay consumes historical rows that skipped turns would not have
emitted, so it is neither causal nor an exact replay of this patch. It
motivates the floor; deployment needs its own measurement. Signature-only
delay figures, including a 35.8-minute maximum, must not be attributed to
the floor variant.

## Tests

`tests/test_monolith_fastpath.sh` drives the real step using a temporary
identity, stub shellm and no model calls. It checks skip chains, scaffolding,
floor boundary, clock regression, corrupt state, inbound/delivery/memory
changes, pending requests and failed probes, work/error recovery, due
schedules, share nudges, and a backoff cap longer than the floor.
`tests/test_monolith_backoff.sh` explicitly disables the fast path to keep
the pre-existing backoff contract under separate test.
