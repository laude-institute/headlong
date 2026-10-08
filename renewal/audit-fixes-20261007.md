# October 7 audit remediation

Based on selected commit 6093192bb18d3dab165d99f7df6d8243fc7ec9eb, retaining the
PR-discovery fixes and the independently edited live Signal skill.

- Signal contact eligibility canonicalizes labels, targets and routes, reads actual
  action/native receipts in bounded read-only batches and reads the host outbox
  for sends accepted before the client wrote its local record, distinguishes unsent from
  accepted and unknown sends, and reports an exact UTC resume time. The guard's
  derived index reads raw message metadata because old indexes omitted action IDs.
  No transport receipt or original trajectory is rewritten. Immediate responder
  replies and correlated follow-up exemptions retain their existing behavior.
- Kitchen delivery classification excludes bare URLs and clear Apple technology
  references. A verified household source still binds its reply; groceries and
  checkout messages retain consent checks. Older non-household tasks cannot be
  automatically closed by a household stop message.
- Existing own native todos/goals can carry structured event/time waits and notes
  in a sidecar bound to the file hash. Edits, expiry and mem done invalidate waits;
  they never manufacture operator provenance or extend expiry. Newer optional news
  sent with its goal waits behind an older explicitly parked contact until a useful
  contact decision, expiry, edit or explicit contact resolution. No automatic send.
- custos-evidence review-publish reconciles repository/PR/head/disposition against
  GitHub before publication, retains attempt journals across timeouts, and reads
  back the actual review. Meaningful disposition changes remain possible; another
  same-disposition update requires linked new evidence. The skill uses the helper;
  it is not a global interception of arbitrary gh/API calls.
- Dream selection flags unscoped numeric Signal cooldown summaries, and keep
  rejects those summaries until scoped or marked uncertain. A one-time operator
  cleanup uses the existing hash-checked dream revision API and retained preimages.

The host companion change adds delivery-status-batch to the current installed
custos_actions module and updates custos_kitchen. Install with source-hash checks
and backups, then restart the existing actions and bridge services. No policy,
allowlist, host network rule, delivery database or supervisor contract is changed.
The additive receipt endpoint can remain during a guest rollback.

Qualification uses hermetic offline VM fixtures, including native runtime commands,
receipt failures/unknown states, alias equivalence, mode/cross-room separation,
partial index writes, kitchen consent, own-goal continuity and review timeout/dedup.
Actual deployment evidence, hashes, requests and operator memory cleanup receipts
are retained in homelab/custos-audit-fixes-2026-10-07/README.md.
