# Scheduled goals: due windows computed by the harness, sends that happen once

Status: BUILT 2026-09-18, tests green, pending commit and deploy. 71 core
lines (10,787 to 10,858 of the 11,000 gate). Code: `chat send --key` and
`_refuse_key` in `bin/chat`; `--schedule` and `--tz` in `bin/mem`;
`_schedule_signals` in `thinkers/_lib/common.sh`, wired in
`thinkers/monolith/step`, one rule in `prompt.md`. Tests:
`tests/test_scheduled_goals.sh`, two checks added to
`tests/test_monolith_wake_sections.sh`.

Related: [outbound_delivery.md](outbound_delivery.md) parts 5 and 6 are the
sent ledger and the exact-text repeat refusal this design builds on.
[related_memories.md](related_memories.md) covers how goals reach the wake
prompt. [conversation_memory.md](conversation_memory.md) part 5 is the
pending request signal whose shape this design copies.

## The problem

On 2026-09-18 Audel posted the same "Friday 9am PT" daily papers message
five times in three hours (02:48Z to 06:05Z), three of them pinging Nick.
Nothing in the tooling was broken. The message index was healthy. The wake
prompt listed the earlier sends under "Sent in the last 24h" with the rule
"do not send again anything listed as delivered". The model sent anyway,
with an empty thought, after reading its staged shortlist file. The repeat
refusal in `chat send` did not fire because the model reworded the message
each time, and the refusal compares the full text.

The same morning showed a second fault. The post was labelled "Friday 9am
PT (Sep 19)" and went out on Thursday evening Pacific time. Friday was
September 18. The wake prompt has no clock, so the model works out the
weekday, the Pacific to UTC conversion and the window from step timestamps.
It has been sending windows hours early since 2026-09-16.

This is the fourth repeated send episode in two weeks (09-08, 09-13, 09-16,
09-18). Each had a different direct cause. They share one structure: a
recurring duty is written as free text in a goal, and on every wake the
model decides again whether the window is open and whether it has already
sent. Audel makes that decision 30 to 100 times an hour. Any per-wake error
rate above zero produces repeats.

## The idea

Move two facts out of the model's judgment and into the harness.

1. Whether a window is due. The goal file carries a schedule. The monolith
   step works out the state of each window and prints it as a routing
   signal, with the exact command to use.
2. Whether a duty has been fulfilled. A send that fulfils a window carries a
   key. The `chat` tool refuses a second send with the same key, whatever
   the wording.

The model still chooses the papers and writes the message. It no longer
does date arithmetic, and a second send for the same window is refused by
the tool.

This is the same pattern as pending requests. There the step prints the
exact `chat reply --follow-up --reply-to ...` command and the observation
carries `resolves=<id>`. That pattern has worked since 2026-09-02.

## Design

### 1. Schedule fields on a goal

Two optional frontmatter fields on a memory of type goal or todo:

```
schedule: 09:00 17:00
tz: America/Los_Angeles
```

`schedule` is a list of local times, 24 hour, separated by spaces. `tz` is
an IANA zone name and defaults to UTC. Each time is one window per day.
There is no weekday filter in the first version.

`mem add` gains `--schedule "<times>"` and `--tz <zone>`, handled the same
way as `--until`. `mem edit` rebuilds the frontmatter from a fixed list of
fields, so it now carries `schedule` and `tz` through as it does `until`.

### 2. Window state, with no epoch arithmetic

For each scheduled goal the step calls `TZ=<tz> date +%Y-%m-%d` and
`TZ=<tz> date +%H:%M` once. Both GNU and BSD `date` honor `TZ`, so this runs
under bash 3.2 on macOS. Local times compare correctly as strings.

The key of a window is `<goal id, 8 hex>/<local date>-<HHMM>`, for example
`1ab0deb4/2026-09-18-0900`.

For today's windows, in order:

- A window whose time is later than the local time now is **upcoming**.
- A window whose key appears in the sent ledger is **done**.
- The latest window that has opened and is not done is **due**.
- An earlier window that opened and was never sent is **missed**. It is
  reported once and never becomes due again. After an outage the mind sends
  one post, not one per lost window.

A window also stops being due `SCHEDULE_GRACE_MIN` minutes after it opens
(default 360), so a mind that comes back late in the day does not post the
morning window at night. The comparison is in minutes of the local day, so a
window late in the evening stops being due at local midnight.

### 3. The routing signal and the clock

The step adds lines to "Routing signals", which already sits after the
recent stream. Everything after the recent stream changes on every wake, so
these lines cost nothing in prompt caching.

A clock line, always:

```
- Now: Thursday 2026-09-17 22:52 PDT (2026-09-18 05:52Z).
```

The zone comes from `HEADLONG_TZ` in `.env`, default UTC.

One line per scheduled goal:

```
- DUE: "Daily papers shortlist for Nick" window 2026-09-18 09:00 PDT. Send it
  once with: chat send --to '<name>' --key 1ab0deb4/2026-09-18-0900
- Scheduled: "Daily papers shortlist for Nick": 09:00 window sent 16:02Z.
  Next window 17:00 PDT, in 6h58m. Nothing to send for this goal before then.
```

The "in 6h58m" text is the only arithmetic. It is computed from the two
HH:MM strings inside the same local day, so it needs no date parsing.

### 4. Keys on sends

`chat send` takes `--key <key>`. (`chat reply` does not: a scheduled post is
a send, and replies already have the answered guard.) The message step records
it as a `key` field. The message index keeps the field. `chat sent` prints
it, and the Sent section in the wake prompt shows it in brackets.

When a key is given, `_refuse_repeat` checks the key before it checks the
text. It refuses when a message from this identity with the same key exists
and its delivery state is delivered, pending, or unconfirmed. A send whose
delivery FAILED does not count, so the mind can fix the address and send
again under the same key. The key check has no time window, because the
date is part of the key. `--force` overrides it, as it does today.

The refusal text names the earlier send: when it went, to whom, and its
step id.

### 5. What this does not do

- It does not stop a send without a key. The model can still run a plain
  `chat send` to the same channel. The harness no longer invites it: the
  signal says the window is done and when the next one opens. Whether that
  is enough is what the first week of live data will show. A stricter
  option is listed under open questions.
- It does not schedule wakes. Wake timing is unchanged.
- It does not cover duties that end in something other than a message. A
  later version can count any step that carries the `key` field.
- It does not migrate goals by itself. Audel's papers goal needs the two
  fields added by hand, and its body should lose the window arithmetic.

## Size

Core lines are at 10,787 of the 11,000 gate, so the budget matters.

| Piece | File | Lines, estimate |
|---|---|---|
| `--key` on send and reply, field on the step | `bin/chat` | 10 |
| `key` in the index and in `chat sent` | `bin/chat` | 4 |
| key check in `_refuse_repeat` | `bin/chat` | 14 |
| `--schedule` and `--tz` | `bin/mem` | 10 |
| `_schedule_signals` and the clock line | `thinkers/_lib/common.sh` | 40 |
| wiring, Sent section shows the key | `thinkers/monolith/step`, `common.sh` | 6 |
| one rule sentence | `thinkers/monolith/prompt.md` | 0 (not code) |

The build came to 71 lines of the 213 left. Tests sit outside the gate:
`tests/test_scheduled_goals.sh` covers the key (refuse on same key with new
wording, allow after FAILED, `--force`), the `mem` fields, and the signals
with a pinned clock (upcoming, due, done, missed, grace, only the latest open
window due, expired goal skipped). It passes under bash 3.2.

## Rollout

1. Build and test locally. Run the macOS bash 3.2 gate.
2. Deploy, then sync `monolith` and `_lib` to both identities. No restart.
3. Add `schedule` and `tz` to Audel's papers goal by hand and trim its body.
   Set `HEADLONG_TZ=America/Los_Angeles` on both boxes and in both SSM
   parameters.
4. Tell Audel in one message what changed: the signal tells it when a
   window is due, and the key makes the send happen once.
5. Read a week of `chat sent` on the papers channel: sends per window, sends
   without a key, refusals.

## Open questions

- Strict mode. A scheduled goal could name its destination (`to:`), and
  `chat send` from the monolith to that destination could require a key.
  That closes the keyless path, at the cost of blocking an unrelated
  proactive post to the same channel unless it uses `--force`. Leave it out
  unless the first week shows keyless repeats.
- Weekday filters (`days: mon-fri`). Left out until someone needs them.
- Whether the responder should see the clock line as well. It answers
  questions such as "what time is it for you" from the same missing data.

## Closing a window without a send

A window is done when its key is in the sent ledger, but a task can also
decide a window needs no post at all and close it on its own: bin/papers-skip
writes the key into notes/daily-papers/closed-keys.md, one key per line. The
chat ledger does not know about those keys, so before 2026-09-30 the routing
signals kept offering such a window as DUE NOW and the mind re-made the same
skip decision on every wake.

_schedule_signals therefore also reads SCHEDULE_CLOSED_KEYS, a path to a
plain one-key-per-line manifest, and treats any key listed there as done,
reported as "the window was closed without a post" so nobody waits for a
delivery that is not coming. A missing or unset manifest changes nothing.

The manifest is read for key-shaped tokens anywhere in the file, not for bare
lines: the real ledger (notes/daily-papers/closed-keys.md) keeps its keys in
prose bullets, and a .skip receipt carries its key on a key= line. A column-1
parse matched none of them, so the fix as first drafted would have left the
stale DUE NOW flash alive even after it merged.

Deploy still has to point SCHEDULE_CLOSED_KEYS at the manifest. Until it does,
a closed window is offered as DUE NOW as before, and the mind answers a key it
has already adjudicated with its drop command rather than re-deciding it.
