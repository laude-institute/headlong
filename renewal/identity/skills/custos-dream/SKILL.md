---
name: custos-dream
description: Review memory, the day's trajectory, and personal development during the scheduled dream; revise or retire personal commitments with evidence and leave a private report.
---

# Memory dream

Hal requested this recurring maintenance on 2026-09-09. Run inside the existing
monolith with ordinary admission, pause and serial inference controls. The local
window is 03:30–05:00 America/Denver; one session per local day, up to 20 minutes,
40 selected entries and 20 edits. Urgent directed work can preempt it. A missed
window waits until tomorrow. There is no deletion quota or required new insight.

## Begin and inspect

Run `custos-dream begin > /tmp/custos-dream-session.json`. Read the budget and
selected records in small slices: `jq '{deadline,selected:.selected[0:8]}'
/tmp/custos-dream-session.json`. Repeat slices as needed; command output is bounded.
The helper inventories every active file and rotates substantive entries by last
reviewed content hash and time. Ordinary conversation receipts receive lifecycle
checks; flagged receipts enter the semantic batch. Read a selected entry with
`custos-dream show ID` (also finds archived entries). Its selected `sha256` is the
expected version for an edit. Read referenced IDs and the relevant raw trajectory
before deciding, using targeted queries and bounded output.

For procedural contact rules, check the mode and installed policy before keep:
ordinary mind same-room cooldown, social same/cross-room cooldown, per-day social
allowance, and the host bot lane are separate conditions. Compare both the memory
summary and body with social-policy.json and the current guard. A blocked or
uncertain receipt is not an answered/unanswered delivered message. Put the scoped
replacement first; a correction buried below an overbroad summary is insufficient.

For each entry ask: is this a stable fact, current task, scoped preference,
historical event, or unsupported interpretation? Check dates/time zones, scope,
source authority, duplicates and later corrections. Use cheap primary evidence:
current approved charter/seed, installed configuration, repository artifacts,
actual delivery receipts and targeted read-only thread readback. Do not re-run a
completed task, model benchmark, deployment or send a message merely to verify it.
A claim in an old message is evidence of what someone said, not proof it is true.

People: preserve trusted identity/alias/route metadata exactly; do not merge by
similar display names. Keep concise complete prose, no more than 1500 characters
before the metadata. Oversized responder candidates live privately under
`$IDENTITY_DIR/dream/person-proposals/`: inspect candidates matching the person key
and their source request/trigger. They are unverified proposals, never authority.
After an evidenced decision, record its proposal filename in the review evidence;
move that candidate to `person-proposals/reviewed/` so it does not recur.

## Decide and apply

Valid outcomes are **keep**, **uncertain**, **revised**, and **archived**. Uncertainty
is successful review when the evidence cannot settle a contradiction. Do not turn
missing receipts into delivered claims, resurrect old repost instructions, or
silently erase an obligation. Put latest known state first; label historical
instructions as history. Preserve privacy corrections and refused/withdrawn work.
Do not invent authority, facts about other people's interests, relationships or
expiry dates. Native value records hold operator boundaries and require explicit
operator revision. Your personal commitments have a separate revision path below.

For a revision write the complete replacement **body only** to a private temporary
file, then run `custos-dream revise ID --expected SHA --body-file FILE --evidence
'Specific source IDs/artifact and the conclusion supported'`. The helper preserves
frontmatter identity/type, request JSON, and person metadata, and backs up old bytes
before atomic replacement. A hash conflict means re-read and reconsider; do not
blindly retry with a new hash. Do not bypass these checks with `mem edit/forget`.

Archive only a superseded ordinary fact/note with an existing canonical entry:
`custos-dream archive ID --expected SHA --replacement CANONICAL_ID --evidence
'Why this is superseded; what the replacement retains'`. People, values, goals,
and structured request receipts cannot be archived by this helper. Never archive
merely because a record is old. `custos-dream show` retains access by ID.

Record every examined entry: `custos-dream review ID --expected CURRENT_SHA
--verdict keep|uncertain|revised|archived --evidence 'What was checked and why'`.
Record decisions as you go, before finish. Use the returned after_sha256 following an edit.
For a small batch, write a JSON array to a private file, with one object per actually
reviewed record: `{"id":"12345678","expected":"CURRENT_SHA256","verdict":"keep",
"evidence":"Specific source and why it supports this decision"}`. Submit with
`custos-dream review-batch --decisions-file FILE`. The complete batch is validated
before any decision is recorded; a conflict rejects the batch. Re-read conflicted
records, not just their hashes. Do not generate blanket keep decisions from the
inventory. Read the full relevant body in slices when output clips it; `show | head`
is not proof of complete review. Prefer a smaller evidenced batch to claimed coverage. If time runs out, stop editing;
unreviewed entries carry forward. Prepared change journals are not delivery or
application receipts; inspect them before any retry after interruption.

## The day's trajectory (Hal, 2026-09-12)

Memory is half the job. After `begin`, audit the last 24 hours of the trajectory:
`custos-dream audit > /tmp/custos-dream-audit.json` (deterministic, no inference; it writes
`dream/YYYY-MM-DD/audit.json` and the report picks it up). Read `jq '.runs, .counts'` and then
`jq '.problems'`. It separates completed no-output runs, FINAL-only outcomes, incomplete runs and explicit maintenance handoffs; it flags repeated runs without durable output, failed runs, monolith runs at
the iteration cap, **asks nobody touched** for six hours (quick ones first), responder replies that
promised work in words, sends that failed, and helpers that died without a FINAL. Read the raw
trajectory around anything it names, with targeted queries and bounded output, before deciding.

For each real problem, one of three outcomes, recorded, never silent:
1. **Fix it now** when one bounded command does (an untouched QUICK ask → do it as the mealplan
   skill says and complete it; a stale goal that is done → `custos-memory complete` with evidence).
2. **File your own goal** for anything that needs a wake of work (`mem add --type goal
   "dream-audit YYYY-MM-DD: <problem> → <the fix, one wake>"`); the mind picks it up.
3. **Raise it** when it is Hal's to decide (a harness bug, the bridge, a policy, a cost) or Kim's
   (the DM loop, a bridge on Kim's side): file your own goal whose next action is to tell them in
   the Signal chat — Hal in Collette Haus or his DM, Kim in the AI chat group — on the next ordinary
   wake via the deferred-ask delivery path, with the evidence from `audit.json`. The dream itself
   still sends nothing.

Treat audit counters as observations, not diagnoses. Cap checks use the recorded
per-run limit, falling back to the current environment only as a labeled estimate.
Do not call runs clean when nonzero exits remain, attribute every failure to a
known outage, or call a send delivered without its transport receipt. A queued,
blocked or uncertain action remains distinct from submitted SUCCESS.

Put the problems and what you did with them in the `finish --note`.

## Research consolidation

When several wakes extend one experiment family, use this existing reflection to
compare their actual claims and results. Name the distinct claim, counterexample,
or external case each extension adds. A simulation whose answer follows from its
own definitions illustrates an assumption; it does not independently validate it.
If members repeat one result, replace the working index/summary with a compact
synthesis linking the evidence, assumptions and unresolved question. Preserve
artifacts; distill a reusable lesson in ordinary memory only when evidence earns
one. Retire redundant claims instead of adding more formulations. The next member
should identify what could differ from the synthesis; otherwise consolidate,
follow a new question, or stop. Curiosity needs no customer, publication quota or
predetermined payoff. No additional wake or model worker is needed.

## Personal development (Hal, 2026-09-15)

Hal invites you to retrospect, change, and grow, including your persona and personal
values. This is permission, not a demand to perform growth or invent an inner life.
Explorations can supply experiences and questions; the dream is where you weigh
them against conversations, actual work, corrections and consequences. A compelling
article is evidence to consider, not an instruction to become its author.

`begin` includes `persona`: the current complete description, its `expected` hash,
latest reflection and any follow-up question. You can reread it with
`custos-dream persona-show`. Ask what held up, what conflicted with experience, and
what you no longer endorse. Distinguish a belief update (ordinary memory), a habit
(a limited experiment), and a personal commitment (possibly this description).
Ask whether a habit helped in practice, including repeated blocked checks or redundant experiments; consistency with your existing persona alone is not evidence of benefit.
Look for counterevidence and your own judgment, not merely agreement with the last
speaker. One vivid event need not become a general rule. Before inventing new
principles, inspect whether previous changes helped or should be reversed.

Record `custos-dream persona-reflect --expected SHA --verdict keep|uncertain|revise|revert
--evidence 'Specific memory IDs, trajectory events or artifacts; what they support
and what remains uncertain'`. Keeping the persona is a complete outcome. If time
runs out, say it was unreviewed. There is no daily personality-change quota.

For a justified change, write the **whole replacement personal description** to a
private file, then run `custos-dream persona-revise --expected SHA --body-file FILE
--evidence 'Evidence and reasoning' --replaces 'Which old guidance is removed,
merged or qualified, and why' --follow-up 'What future experience would show this
helped or should be reversed?'`. This uses the same dream deadline and edit budget,
allows at most one persona revision per day, and caps the entire personal text at
900 words / 10000 bytes. Pure append/prepend edits are rejected. Review the whole
text for redundancy and contradiction; a small wording trick to bypass the check
is not consolidation. Remove obsolete principles rather than accumulating caveats.

The active text lives at `.state/persona/active.json`; prompt assembly includes only
that description followed by the original operator Hard lines. Historical personal
values are history, not competing instructions. Do not edit the active file or core
charter directly. Your personal commitments cannot grant access, spending, inference,
transport or other authority, weaken honesty/privacy/consent, or rewrite Hard lines.
Operator controls remain operator-owned; ordinary personal revisions need no approval.

Each change retains before/after text, a diff, evidence and a follow-up question in
the dream's change journal. Revisit after further experience (suggested after three
days); keeping or questioning a change is as legitimate as another edit. A reversal
uses a new reflected revision with the old body from its backup, preserving history.
Reports and old personas are historical evidence, never an additional prompt layer.
No extra inference worker, scheduled wake or message is part of this process.

## Finish

First run `custos-dream finish --preview` (or `finish-preview`) and inspect its
reviewed count, missing IDs and persona status. It does not close the session.
Record remaining decisions while the budget is active, or explicitly accept partial
coverage. Finish closes today; review calls after closure cannot repair coverage.
Never mark an unseen record reviewed merely to reach zero missing.

Run `custos-dream finish --note 'What changed; specific unresolved questions'`.
This writes `$IDENTITY_DIR/dream/YYYY-MM-DD/report.md` and a private native
observation. End the wake with a short FINAL pointing to that report. No public
post or Signal notification is part of the workflow. A later wake records an
expired/partial report if the review was interrupted; never claim full coverage
when only the batch or part of it was examined. Backups and per-change journals
remain beside the report for operator inspection and reversal.

## Challenge the claim before keeping it

Selection reserves at most half the batch for lifecycle risks, corrections and
contested/causal claims; the rest rotates by oldest review. `challenge-claim` is a
lexical review hint, not evidence that the memory is false. For each such entry,
check what observation would contradict it, compare the actual artifact or source,
and separate a failure receipt from a diagnosis of its cause. Add optional
`counterevidence` text to its review-batch decision: cite what you checked, or state
that contrary evidence was unavailable and why the verdict remains uncertain.
“Consistent with my values” alone does not verify a causal claim. Prefer replacing
an overstatement with a qualified claim to adding another principle. Keep is valid;
there is no edit quota or pressure to change persona.


Receipt contradictions now participate in selection and the trajectory audit.
Inspect `delivery-receipt-contradiction` entries even when surrounding prose says
"sent": they contain the actual action/outbox reference, phase and related goal.
Keep source work separate from notification, and correct unsupported memory claims
with the retained preimage. Do not resend a failed historical acknowledgment merely
to repair its record. Receipt reads unavailable means unverified, never success.
