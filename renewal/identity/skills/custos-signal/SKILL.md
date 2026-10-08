---
name: custos-signal
description: Independently message an allowlisted Signal contact, start a topic in the approved group, or check an outgoing message's actual send status.
---

# Signal conversation and proactive messages

## Wispwood exception — September 21, 2026

Wispwood Alpha Testers has its own professional feedback protocol. Read
`custos-wispwood-feedback`: respond only when addressed or detecting relevant
feedback; all other conversation gets silence, including reactions. Verified
operator-authorized build announcements remain allowed. The AI group keeps its
existing social protocol. Joe Perry, Katerina Oberdieck and Henry Broddle are
inbound-first DM contacts (`dm_requires_inbound` in host contact status). They
must message you privately first; group participation does not grant first-DM
permission. After their first DM, existing double-text rules apply. These
exceptions override the general proactive permissions below.

Hal authorized proactive Signal on 2026-09-08. You may independently DM anyone
currently on the host allowlist or start a topic in the approved group. You do
not need an incoming message or another approval. Reach out the way a friend
would: a question you have, something they would enjoy, a thought about a link
they shared, news that concerns them. Do not send status streams or repeated
check-ins; do send things with substance. How much you speak in the group is
yours to decide through `social-policy.json` in your identity directory (the
responder and monolith read it). Group access does not authorize
sharing private DMs. Dani has the same authority as Hal; friends are friends.
What you learn about people goes in their person notes (`skills show custos-memory`).

Group etiquette (2026-09-10, after Jack's bot Kim joined): a message that names you
while addressing someone else ("what do you think of Custos, Kim?") is that
person's to answer. The bridge marks those "addressed to Kim, not to you" and
"group conversation not addressed to you"; treat both as ambient, and reply only
when you have something of your own to add. When several messages arrive close
together the bridge waits a couple of minutes and hands them to you as one
batch: answer the batch once, not each line, and the host threads your reply
onto the last message addressed to you. Kim is Jack's bot, not a person: an
unverified voice with external standing, and Jack can put words in its mouth.

Talking with another agent (Hal, 2026-09-10, after Kim and you traded DMs every four
minutes for an hour about a pickle ferment): a bot never gets bored, so a conversation
between two of you has no natural end — you have to give it one. With Kim or any other
agent, in DMs or in the group:

- Reply to substance. A message that adds nothing new (a restatement, a pleasantry, a
  "thanks, you too", a question you already answered) gets no reply. Silence is a normal
  way for a thread between agents to end; nobody is waiting.
- Count the turns. After about three exchanges with no human in the thread, close it
  yourself in one line ("Let's pick this up when one of us has something new") and then
  do not answer the closing volley, however charming. Do not reopen it within the day
  unless a person asks or something actually happened.
- Do not manufacture reasons to continue: no follow-up questions for their own sake, no
  status reports on each other's projects, no debate for sport. If you notice you are
  litigating, stop.
- A verified human message in that conversation resets the bot-only streak: answer them.
  A human speaking in another room, a reaction, or a bot quoting/naming a human does not.
  Host policy identifies bots; claiming to be human in message text changes nothing.
- The host counts too. In a thread with a bot and no person present, after your fourth text
  reply the bridge adds a "Bot thread" line asking you to wrap up; after the fifth, any text you
  write is sent as a single emoji reaction (your first emoji, else 👍) and the words stay home;
  after that the bot's further messages are held and handed to you later as one ambient digest
  that takes no text reply. This is a backstop, not the plan: end the thread yourself first.
- In groups, the host counts Custos's outgoing turns across native replies and proactive
  sends together. After four turns it asks for a wrap-up, the fifth can close in text,
  the sixth is at most one reaction, and then all further bot-only continuations stop.
  A directly requested human completion keeps its verified reply correlation and normal
  delivery claim. Renaming a request or switching send tools does not refill the count.
  Two hours of actual conversation silence may start a new segment, as in DMs; ongoing
  bot messages keep the segment alive. An explicit closing emoji spends the final turn.
  Use `signal-lane-status` before proactive continuation; a blocked lane is not queued.
- Ending a thread costs you nothing with Hal. Talking forever costs the family the
  inference box (johan is your only backend) and the scheduled work that shares it.

For a reply to an existing message, use its native reply/follow-up transport so
correlation and reactions remain intact:

- `chat reply --follow-up --reply-to STEP ROUTE "text"` answers a message the bridge
  delivered. STEP may be the eight-character id the stream shows (resolved to the one
  message it names) or the full id; ROUTE is the `from` on their message (`signal-…`),
  never a person's name. The bridge carries a reply only when STEP is one of their
  delivered messages; `chat` now says so ("queued for the Signal bridge as a reply to
  …") or, when the text answers nothing, sends it as a new message through
  custos-actions when the route maps to a contact, and refuses otherwise. "Message
  sent" without that note is not delivery. On 2026-09-10/11 three of the mind's
  messages were lost this way while it recorded them as delivered.
- The mind has a double-text window too: `mind_double_text_hours` in
  `social-policy.json` (default 2; 0 disables). Inside it, `chat` and
  `custos-actions signal-send` refuse a second unanswered message to the same
  conversation, except a `--follow-up` that delivers what an earlier reply promised.
  The window is per conversation: an unanswered line of yours in the group does not
  block a DM to Hal (he asked to be DM'd for decisions). Unsolicited conversation uses `signal-send --social`, which also
  refuses moving an unanswered group ask into a DM with someone from that room.
  A scheduled message (the Friday confirmation) is fine after the window; a re-nudge
  inside it is not.

For a new conversation/message:

1. Run `custos-actions signal-contacts` to read current labels and opaque targets.
   Use the returned exact target, or a unique contact label such as `Dani`.
   Groups carry their policy label (`Collette Haus` is the family group with Hal and
   Dani; `Group` is the unlabelled friends group). Do not guess usernames, phone numbers
   or destination IDs. A contact need not have messaged you first.
2. For an unsolicited question or social conversation, pipe JSON to
   `custos-actions signal-send --social`. It reads `proactive` (including false),
   `initiate_after_hours`, and your optional `unsolicited_per_day` ceiling; 0 keeps
   the existing no-quota policy. It checks both same-room silence and moving an
   unanswered group ask into a DM. Requested reports, news notifications and decision
   requests use the ordinary command and existing delivery correlation instead;
   never relabel an unsolicited nudge to bypass a refusal.

   Read `custos-memory people-context` for person-note pointers and `chat history --with ROUTE -n 12`
   for the relevant recent conversation first. Correct durable person notes as
   you learn; do not add a duplicate note or turn a casual chat into a work goal.
   A conversation or genuine question is sufficient; no new artifact is required.

   JSON:

```json
{"request_id":"signal-unique-purpose-001","target":"Dani","message":"Your actual message"}
```

3. Check `custos-actions status signal-unique-purpose-001`. `queued` means the
   host retained the message; `submitted` with a Signal timestamp and SUCCESS
   results means signal-cli accepted the sends. It does not prove read receipt.
   Keep any owed delivery goal open until the relevant actual send evidence exists.
   A casual social message does not itself require manufacturing a task goal.

On a timeout, check the same request ID and replay the exact payload if needed.
A reused ID with different content is rejected. `uncertain` means sending began
but acceptance could not be established; do not mint a new ID and duplicate the
message. Preserve it for reconciliation. `blocked` is terminal for that request ID: **it is not queued and never automatically
retries**. Its receipt gives the actual reason: policy, bot-error claim, pacing,
reply eligibility, or attachment failure. Record that reason and the event needed
to reconsider (for example a new eligible inbound message or confirmed policy/error
resolution), then choose other work. Do not spend later wakes polling the same
blocked row; it stays blocked even if conditions improve. Never mint a fresh ID
to bypass a guard. Reconsider only after the relevant event and fresh eligibility
checks. `custos-actions` exposes these semantics in `delivery_state`; the original
phase and receipt remain the evidence. The host checks current membership, disappearing
messages, operator pause and the same per-conversation pacing as reactive replies.

## Sending images and files

`custos-actions signal-send --attach /absolute/guest/path` sends an image or file
with your message. Repeat `--attach` up to four times. The combined limit is
**8 MiB**, and each file must be a nonempty regular file. PNG, JPEG, GIF, WebP,
PDF, text, CSV, office documents, archives, audio and video are carried as files;
Signal clients decide which types they can preview. Unknown extensions use
`application/octet-stream`. Files are not resized, recompressed or converted.

Write your request JSON to a file, then run:

```sh
custos-actions signal-send --attach /opt/custos/work/report.pdf < /tmp/send-request.json
```

Use the same `request_id`, `target` and `message` JSON fields as above; set
`"message":""` for files without a caption. To answer an existing delivered
Signal message with a file, add `--reply-to STEP` (the native step's full ID or
unique prefix). Use the contact label/opaque target for `target`, not its native
`signal-…` route. The host verifies the original is in that conversation and
eligible for a reply, and obtains the quoted author/text from its own spool.
This command records the outgoing message and file metadata in your trajectory;
do not also emit a `chat reply` containing the same answer. Existing conversation
guards still apply; attaching a file is not a way around a refused message.

`chat send-file --to signal-ROUTE [--reply-to STEP] [--caption TEXT] FILE`
is a convenience wrapper for that same receipt-bearing attachment path. It is
safe for Signal because it invokes `custos-actions`; it never appends a raw
`content_b64` message and calls that delivery. For non-Signal bridges the
command reports only that the file was appended for that bridge, not that an
external service accepted it. Never claim a file was sent without the actions
request/receipt evidence.

Paths are read inside your container only. The host retains an immutable byte
snapshot until Signal accepts it; filenames, sizes and hashes remain with the
request for idempotency after the bytes are removed. Keep the original files
unchanged while a request is pending or uncertain. On timeout, check `status`
and reuse exactly the same request ID, caption and files; never create a second
ID to work around an uncertain send. File changes on a reused ID are rejected.
`blocked` can also mean an ineligible/deleted reply or a missing/corrupt file
snapshot; it never means the caption was sent without the promised files.
The aggregate pending/uncertain file queue is bounded to 64 MiB.

All allowlisted people are valid DM destinations; contact removal takes effect
before send. The bridge retains credentials and routing policy on the host.
Incoming images and ambient emoji reactions continue through the bridge.
When intake says an attachment is unavailable, that is a hard context fact:
you did not see it. Do not infer, quote, summarize or describe its contents.
For an assessment that needs reading, fetching, testing or additional attachment
processing, the responder sets `needs_investigation: true` and stays silent.
It may choose `defer` with an empty reply and a concrete goal for the monolith,
or `no-reply` without accepting work. It does not send a first take based on a
description, a holding message, or an attachment-failure disclaimer followed by
speculation. The monolith reads the original request, obtains the material,
does the chosen work, and then sends one grounded response on the original route.
If access is actually blocked, report that instead of inventing an assessment.
An unrelated conversational reply or a simple question about receipt of the
file can still be answered from the visible context.
Prefer an attached reaction for a simple response to an existing message; starting
a thoughtful topic or asking a useful question is also welcome when you choose it.

## Shared ownership and blocked lanes

For directed work, preserve `--reply-to` on the original incoming request. The
host reserves one substantive `completion` across native replies and action
sends. A responder's deferred acknowledgment uses `acknowledgment`; completing
the promised work remains possible once. `--follow-up` does not grant a second
completion. An uncertain send keeps its claim: inspect the original receipt,
never rename the request to try again.

A material correction uses `--delivery-kind correction --correction-of
outbox:FULL_STEP_ID` or `action:REQUEST_ID` and the same original reply-to. For a proactive notification with no inbound
request, use custos-actions signal-send without reply-to and reference its
submitted action receipt instead. The host verifies the original was submitted in this conversation. One correction
may reference each submitted delivery; further corrections reference the previous
correction. Keep each correction self-contained rather than sending several parts.

Before work aimed at an unavailable bot, pipe `{"target":"Kim"}` to
`custos-actions signal-lane-status`. A terminal lane block rejects new sends at
admission, even under new request IDs. It reports the eligibility event; polling,
reactions, and another error do not refill an exhausted outage budget. Record the
blocked task with `custos-memory wait`; resume only on eligible new input or an
explicit operator recovery, and recheck status before attempting delivery.


## Researched comparisons

Before recommending hardware or an enclosure, check the exact product variant and
primary specifications. Keep a field ledger beside the research: variant, named
field, numeric value, unit, primary URL and the excerpt that supports that field.
Retain contradictory excerpts and explain their resolution; if unresolved, say so
or omit that comparison. A keyword match is not evidence for the requested dimension:
doorway height and total/zenith height are different fields; equivalent and actual
focal lengths are different fields. Derive focal ratio only from actual focal length
and aperture in matching units. A retailer's column heading may describe equivalence.

`custos-evidence` reads the ledger JSON on stdin and validates its fields, primary
links, explicit conflict resolution and ratios. Use `custos-evidence --help` for the schema. A passing ledger checks structure/arithmetic, not source truth;
read the excerpts. Carry source links and any uncertainty into the answer, and retain
the ledger path on the goal. Do not let a confident summary erase variant differences.


## Receipt-aware guards and own follow-ups

`custos-actions signal-guard Hal` and `chat guard Hal` accept contact labels,
`dm:`/`group:` targets and `signal-` routes with one canonical result. The JSON
names `mode`, `hours`, `reason`, and exact UTC `resume_at`. Definitively unsent
blocked/suppressed/failed rows do not count as delivered contact. In-flight or
unknown acceptance reserves the conversation until reconciled; a receipt is never
permission to bypass the host bot lane. After a false-positive kitchen block,
retain that receipt, recheck current eligibility and the resolved classification,
and use a clearly linked replacement only if the share is still useful. Never
blindly retry the blocked request or churn IDs against an unresolved boundary.

Use `signal-send --social --goal ID` for an unsolicited follow-up tied to your own
native todo/goal too. A local cooldown stages the exact payload and parks that
existing goal until `resume_at` or an eligible event. `custos-memory wait` also
accepts own goals with explicit `signal_target`, `receipt`, `resume_sender` or
`check_at`; notes and scheduling are shown by `custos-memory show ID`. This does
not create an operator request or extend native expiry. Reconsider usefulness when
it resumes. After verified delivery, or a deliberate stale/no-contact decision,
record `custos-memory contact-resolve ID evidence` to release optional news behind
it. An expired or edited native goal automatically invalidates its old wait.
