# Conversational kitchen tuning — 2026-10-04

Hal approved the audit's implementation. Food context does not authorize shopping;
structured, source-quoted kitchen intent travels through the existing responder.
Actual changes silently defer to native tasks; completion ends after verified help,
independently of purchase. Closure persists outside person prose. Send-time guards
cover native replies and proactive actions. Requested reminders retain source
correlation. The three forced kitchen schedules are retired in defaults and by the
operator migration; quiet catalog maintenance remains.

`mealplan context` reads host-verified household intake, including messages still in
the batch window. Revision/cursor checks and a five-minute lease naming a native goal
serialize writes and reject stale work. The kitchen API owns revisioned patches,
source-scoped choices, inventory, contribution aggregation, retailer operation
journals and owned-calendar synchronization. Old bulk cart routes refuse writes.
The kitchen service is deployed separately from this release.

`host-kitchen/` retains the actual deployed host bridge base with only the kitchen
hooks added, including existing video and restricted-contact patches absent from
this guest's base commit. It is a separately installed, operator-owned component;
never overwrite the host with the guest bridge file. `custos_videos.py` is the exact
existing host dependency, retained here for isolated qualification of that candidate.
The host also receives this release's `custos_kitchen.py` and retains all other files.

Qualification: full offline harness suite plus incident replays and a test of both
queues against the actual host candidate; no live transport or retailer writes.
Keep deployment request/receipt hashes and migrations in the homelab implementation
record. Code rollback does not rewind household state or restore contact schedules.

Limits: retailer calls cannot be atomic with someone editing the Amazon app. The
system checks before writes and verifies afterward; an ambiguous result is retained
for explicit resolution rather than retried. Legacy cart quantities have incomplete
ownership provenance and migrate as preserved household baselines. Unknown recipe
amounts or package units remain unresolved. A new explicit selection can resolve a
baseline; no bulk refill is allowed as a workaround.
