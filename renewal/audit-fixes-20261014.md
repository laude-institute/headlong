# October 14 audit repairs

The audit found a requested household confirmation becoming an uncorrelated
proactive send, an open guard described as closed, and staged request identity
checking disappearing when --goal was omitted.

Explicit Signal reply IDs now resolve against the inbound transport receipt and
conversation before deduplication. Unknown/wrong-room IDs fail without proactive
fallback. Actions retain native reply and goal linkage across retries. Queue
acceptance cannot satisfy a correlated goal's delivery requirement. Native channel
results explicitly have no Signal receipt.

Signal guard output now includes state, channel, receipt namespace and meaning.
Open/null means no deadline. Receipt waits snapshot the current phase; unchanged
terminal states do not wake them repeatedly. Dependency waits replace hourly news
checks behind older contact decisions. Duplicate comparisons and identical notes
can be recorded once without continuous prompt churn.

All Signal sends retain immutable semantic payloads under .state/staged-signal,
serialized by an advisory lock. A durable attempt marker precedes the host write.
Revision requires exact preimage, a locally-created never-attempted stage, and
host unknown_request. Legacy stages cannot be revised automatically. The immutable
stage survives flag omission, source-file changes and process failure.

News is composed from per-item source files using signal-prepare-batch. The payload
contains hashes and stable source keys; stale groups and repeated submitted or
uncertain items are refused. Routine batches default to a six-hour minimum from
actual successful news submission, distinct from the contact guard. An explicit
time-sensitive reason can waive batching, never contact or correction gates.
Pending corrections take priority. Reopening a window is not an automatic send.

Dream selection and its audit consult bounded actual delivery receipts, including
blocked sends whose surrounding prose claims success. The maintained state-summary
helper reads structured guard state and distinguishes event waits from deadlines.

Voidle is removed from current release defaults and skills. Persistent observer,
charter and memory corrections are a separate hash-checked operator migration,
with preimages and no trajectory replacement or historical resend. The migration
also imports recent news keys so deduplication crosses the release boundary.

Tests run in the disposable no-network hermetic VM. See the homelab repair record
for exact qualification/deployment receipts, migration evidence and rollback.
