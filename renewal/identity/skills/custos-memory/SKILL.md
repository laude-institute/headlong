---
name: custos-memory
description: Work with deferred asks and your own goals in native mem; read and edit person notes; recall evidence; retire a resolved goal without duplicate records.
---

# One durable memory store

Native `mem` holds memory and active goals. The `custos-memory` helper writes that same store; its intake deduplication is not another planner. No five-file ceremony per request.

## Conversation, asks, and follow-ups

A deferral may be silent: `decision: defer`, an empty `reply`, and a concrete
goal create active work for the monolith without an immediate message. For
attachments, papers, links, repositories or experiments needing work beyond the
responder's available context, set `needs_investigation: true` and use this form
if you choose the task; otherwise use `no-reply` without a goal. No first take or
holding reply is owed. When working a silent deferral, read its original message
and evidence references, obtain/read/test the subject as needed, then deliver one
grounded follow-up on the original route. Say what was actually checked and any
remaining limitation. If the source cannot be obtained, report the concrete
blocker rather than a critique of a description. Silence is not task completion;
record verified delivery (or an evidenced decline) before completing the goal.

Every message that reaches the responder is captured as conversation memory before it is answered (crash-safe, replayable). It becomes a **goal** only when the responder decides to *defer* real work; a reply, a reaction, or a deliberate silence settles it and it stays plain memory. So `custos-memory context` lists two kinds of people's items: **deferred tasks** (someone asked for work) and **unanswered messages** (the responder never finished; answer them or let them go). Greetings, chatter, and answered questions never appear there.

If you take on an ask that arrived some other way (a square thread you read, an issue), pipe a JSON object to `custos-memory capture`:

```json
{"request_id":"the-source-stable-id","sender":"the-original-routing-identity","source_url":"the-original-source-url","content":"the-original-request-wording","authority":"external","outcome":"What would satisfy the ask","next_action":"First bounded step","completion":"Evidence needed to call this done"}
```

Use actual source IDs, not a new timestamp on replay. `authority` is `operator`, `agent`, or `external`; only bridge-validated provenance establishes operator authority. If capture fails, do not claim acceptance. Successful stdout is `{goal_id,request_id,created}`; a duplicate reuses the durable request. Capturing an ask records it; it does not commit you to it.

`custos-memory context` gives bounded active context with directed work included. If it reports more pages, use `custos-memory context --json --offset N --limit N` as needed; omission from a page is not completion. Read the whole relevant goal with `custos-memory show GOAL_ID`. Update it by piping JSON to `custos-memory update`:

```json
{"goal_id":"actual-id","outcome":"Current agreed scope","next_action":"Concrete step or named blocker","completion":"Current acceptance evidence","evidence":"Observed result and artifact/source reference"}
```

Send only changed fields. Preserve provenance and useful earlier evidence; do not duplicate a goal for each message or follow-up. A scope-changing follow-up is its own captured request linked to the existing goal's work/evidence, not a second independent promise to do identical work. An acknowledgment, `NO_REPLY`, or asking for permission does not discharge the request.

For deferred work use the exact native follow-up command in the pending signal:

```bash
chat reply --follow-up --reply-to REQUEST_STEP_ID SENDER "Result, evidence, and any limitation"
```

A successful local reply enqueue is not proof of external delivery. For square routes, inspect the adapter receipt/readback using `skills show custos-square`; keep delivery blockers active. After actual delivery (or an evidenced decline/abandonment), pipe `{goal_id,evidence,disposition}` to `custos-memory complete`, where disposition is `completed`, `declined`, or `abandoned`. Evidence must say what happened and where to check it, or why work will not proceed. The helper atomically retires the active goal into native `memory`, preserving provenance and evidence; with the activated trajectory it also idempotently appends the pending-request resolution. Do not separately append another resolution. If intake conservatively captured a non-directive message, promptly reconcile it with an observed non-directive reason rather than leaving phantom work active.

Executable completion shape (replace the sample ID and evidence; do not use
`complete GOAL_ID`, `--evidence`, or other guessed flags):

```bash
printf '%s\n' '{"goal_id":"0123abcd","disposition":"completed","evidence":"Actual artifact verification and delivery receipt"}' | custos-memory complete
```

All write commands read JSON from stdin. Only `show` takes a positional goal ID.
`custos-memory --help` gives these same invocation shapes; do not search old
trajectories for an invocation when the current CLI documents its contract.

## Choosing and recalling memories

- `goal`: desired direction; `intention`: chosen commitment; `objective`: measurable outcome; `todo`: small next action. All are native active-goal types. Prefer one useful level, not all four for the same work.
- `value`: enduring principle; `belief`: revisable claim with confidence/evidence; `fact`: supported observation with source/date; `preference`: a revisable taste; `note`/`memory`: context worth retrieving.
- `person`: one note per person you talk to, which the responder rewrites as conversations happen and shows itself before each reply ("What you know about Hal"). `mem list --type person -s` lists them (second column is the id); `mem show ID` reads one; `mem edit ID "..."` rewrites the note text. The last line of a person note (`Custos person note v1: {...}`) carries the person key and aliases that link a Signal identity, a square handle and a nickname to the same person: keep that line intact when editing, and add a nickname by putting it in the note text (the responder folds aliases in over time). Learning that a nickname or a group label belongs to someone you already know is exactly the kind of thing to record here. One note per person key: find the existing note before creating one, and fold a duplicate into the kept one with `custos-memory person-merge SOURCE_ID TARGET_ID` (aliases and routes union, both preimages archived under `dream/operator-cleanup/`; nothing is deleted). To remove already-known bad aliases without editing a memory file directly, use `custos-memory person-alias-remove PERSON_ID ALIAS [ALIAS ...]`. It atomically removes only the exact, case-sensitive aliases from the selected native person record, preserves the display, person key, prose, routes, other aliases and metadata, and writes one archived preimage under `dream/operator-cleanup/changes` before the native commit; its JSON evidence says whether it removed anything and names that preimage. Absent aliases are an idempotent no-op with no archive or write. This is an operator cleanup tool, not a judgment that an alias explicitly proposed by a model is bad, and it never changes a canonical display. When several notes share a key the responder reads the most recently updated eligible note; resolvable superseded stubs are excluded. Social context uses the same canonical selection. Person merges preserve legacy long prose and archive both preimages; ordinary model-written person updates remain capped at 1500 characters. If a legacy person note has repeated entries in its native `updated:` history, use `custos-memory person-normalize PERSON_ID`. It removes only duplicate timestamps, preserves the body and structured identity metadata byte-for-byte, archives the preimage, validates the candidate, and is idempotent. Validation also rejects a structured alias that the note's prose explicitly calls “a distinct person”; repair that contradiction with one atomic `person-alias-remove` call when multiple aliases are named.
- Self-chosen work: `mem add --type goal "Outcome; next action; completion evidence"`. `mem add --type todo --until YYYY-MM-DD "Bounded next action"` expires after that UTC date; expiry is neither a scheduler nor proof of completion. Do not put expiring deadlines on owed work to make it disappear.
- Recall cheaply: `mem prefilter "specific question" --top 8`, then `mem show HEX_ID`. `mem search "question"` uses admitted inference when lexical recall is insufficient. `mem list --short` and `mem list --type goal` are inventories, not instructions to load every body.
- `mem edit` derives the summary line from the first non-blank line of the text you pass; leading blank lines are dropped, so a body copied from `mem show` is safe. A record that carries a request envelope or a person-note line is validated as the store reads it before the write is kept (`custos-memory validate FILE`); a refused write is restored and the reason printed.
- Never rewrite `memories/` files with your own scripts. If you must (a bulk pass), do it under the store lock and run `custos-memory validate` before you call it done: it re-reads every record and compares each captured message with its trajectory step, exactly the check that set 55 records aside as "Unusable incoming" on 2026-09-11 after a compaction pass changed their provenance. A pass that is not clean gets restored from its backup, not explained.
- Edit existing self-chosen goals with `mem edit HEX_ID "updated complete body"`; keep source, uncertainty, outcome, and next action in the body. Generic edit preserves native type/expiry but drops custom frontmatter, so do not store lifecycle/provenance there. Use IDs returned by mem, not guessed slugs.
- Retire a finished self-chosen goal with `mem done HEX_ID "what happened"`: it dates a DONE line into the body and flips the type to `memory`, which is what removes it from the active count (a body that merely says DONE while the type stays `goal` keeps counting). Use `mem forget` only for records that were wrong to begin with, never for person notes. Directed goals use the helper's evidence-backed completion. Resolved goals should leave active context, not accumulate contradictory status paragraphs.

## Keep people broader than their current project

Person notes are compact profiles, not the storage limit for everything learned
about a person. Keep identity, relationships, broad interests, communication and
consent boundaries there. Put growing domain knowledge in a canonical topic note
and retain a short pointer in the person note. Read before merging; do not replace
the whole person with the subject of the latest conversation, or discard a valid
preference merely because its date is old. A newer explicit correction can
supersede it, with source and scope retained.

For Hal and Dani's meal planning, load `custos-mealplan` and native note e93fc9a3,
**Household meal-planning preferences**. It specifies what to read, how to update
the same note, and what must also change through the kitchen CLI. Weekly inventory
is plan/list state; food/product preferences are topic knowledge. Dani's reminder
boundary and baby-name interests stay in her broad person profile.

## Search execution and coverage

`mem prefilter "query" --top 8` is fast local ranking; `mem search "query"` adds
a semantic model call (medium effort). It is usable but can take longer than 20–30
seconds: do not wrap it in such a short timeout or hide its stderr. Its heartbeat
ends on success, failure or cancellation. If an explicit wrapper is needed, use
`timeout --kill-after=5 650 mem search "query"`; the gateway/client have their
own bounded deadlines. The model receives a bounded candidate corpus. Omitted
or excerpted files are reported, so "no matches" is not exhaustive: narrow the
query or use `mem show` for the actual identified file.

`traj search "literal" -i` is local text search, not an LLM request. Field, regex
(`-E`), context (`-C`) and recursive (`-r`) searches include referenced stdout/stderr
blobs. Malformed JSON records produce a warning naming their lines; preserve
those records for repair and do not pretend the damaged rows were searched.

Scheduled memory maintenance uses `skills show custos-dream`: one bounded review
inside the monolith in the early morning, with version checks, preimage backups,
evidence and a private report. Use its revise/archive commands during a dream.
Untouched ambient non-task records settle after six hours without a reply; accepted
tasks and attempted replies do not expire this way. Oversized person updates keep
the previous complete note and preserve an unverified candidate for later review.

Future-gated directed work: pipe `{"goal_id":"0123abcd","not_before":"2026-09-16T17:00:00-06:00","evidence":"Verified planning window"}` into `custos-memory update`. Use an explicit timezone. The record stays active and visible as scheduled, but stays outside actionable/stale/expiry rotation until that timestamp; age starts at the gate. Set a past timestamp to reopen early. This gate is not a new timer: retain the existing scheduled observation or reminder that wakes you at the intended time.

## Waiting and correcting a delivered result

When the next action needs a human or external event, use structured waiting;
writing “blocked” in a note does not suspend QUICK/OVERDUE scheduling. Pipe JSON
to `custos-memory wait`:

```json
{"goal_id":"actual-id","reason":"Cart prepared; awaiting the person's confirmation","resume_sender":"exact-original-route"}
```

The default resume_sender is the original route. A new directed non-reaction
message from that route makes the task actionable for a gate check; it grants no
new authority and does not establish that the gate was satisfied.
Replayed messages do not. An empty resume_sender requires explicit resume. An
optional `check_at` is an ISO timestamp with timezone for one deliberate check;
do not add frequent check times to an unchanged human gate. Use
`custos-memory resume` with `{goal_id,evidence}` when another verified event
satisfies the gate. Waiting keeps the task and its evidence, without urgency or
automatic expiry. If a new message does not satisfy the gate, wait again.

If later evidence materially changes a result already sent, create a correction
immediately, before FINAL, with `custos-memory correction`:

```json
{"goal_id":"original-goal-id","receipt":"action:original-request-id","evidence":"What changed, with source or memory ID"}
```

This creates an idempotent deferred task and preserves the completed original.
Read the original request and delivery receipt, check the claim, and send a concise
correction through its original conversation. Use `--delivery-kind correction
--correction-of action:ID` (or `outbox:FULL_STEP_ID`) on `chat reply --follow-up`
or `custos-actions signal-send`; reply-to must still identify the original inbound
request. For proactive notifications with no inbound request, use the original
submitted action receipt with custos-actions signal-send without reply-to. Close
only against a successful correction receipt or an evidenced
judgment that no correction is needed. Recording the new caveat in a fact alone
is not delivery.


## Delivery and eligibility waits

`chat reply` prints the recorded step ID. It means pending transport. Inspect
`custos-actions delivery-status outbox:STEP_ID` (or `action:REQUEST_ID` for actions).
Only `submitted` with timestamp and all recipients `SUCCESS` confirms submission.
Suppressed, blocked, converted-to-reaction and uncertain do not deliver the intended
text. A completed native task with a correlated Signal send now checks the actual
receipts; an unresolved send keeps the task active. An uncertain send must be
reconciled, never retried under a new ID. `--follow-up` does not create a second
completion slot. Use the original submitted reference with the correction workflow
above when the message corrects a prior claim.

Park a receipt wait with JSON to `custos-memory wait`:
`{"goal_id":"actual-id","reason":"Waiting for the recorded result","receipt":"outbox:STEP_ID"}`.
Square receipts use `square:traj:STEP_ID`. A guarded discretionary share uses
`{"goal_id":"actual-id","reason":"Staged share awaits an eligible conversation","signal_target":"dm:EXACT_TARGET_FROM_CONTACTS"}`.
The context builder checks the existing guard and receipt state without a model call,
resumes on a terminal receipt or eligible lane, and uses a six-hour fallback check.
Terminal suppression wakes the task for reconciliation, not another send. Keep the
staged text and original eligibility evidence in the goal; do not repeatedly compute
reopening times or poll within a wake. The send-time host guard still decides.


## Event waits and resolved duplicate reviews

A receipt wait records its current phase and resumes only when that phase changes;
a terminal refusal is not a fresh event on every wake. `check_at` is optional for
transport waits, and is an explicit reconsideration time when supplied. A wait can
instead name `dependency_goal`; it resumes when that managed goal is resolved or
an own contact goal is explicitly resolved. Do not extend expiry or add unchanged
notes while waiting. Identical consecutive notes are retained once.

After inspecting a possible duplicate and finding distinct work, persist the
comparison with `custos-memory duplicate-review` and JSON fields `goal_id`,
`duplicate_of`, `evidence`. The warning stays suppressed only while both compared
outcome signatures remain unchanged. A true duplicate should still be closed with
the earlier evidence. Delivery work uses the actual action/outbox receipt; a
successful local edit and an unsent notification are separate outcomes.
