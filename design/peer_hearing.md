# Peer hearing

**In one sentence:** let one Headlong persona hear what another persona
posts on Slack, with a bound that stops the two of them from talking
forever.

Status: built 2026-09-14 for Audel and Harris. When this document and the
code disagree, the code wins. Code: `slack/src/headlong_slack/inbound.py`
(`_on_event`), `state.py` (`PeerGuard`), `config.py`.

## The problem

The Slack bridge drops every inbound event that carries a `bot_id`. That
rule is what keeps a persona from answering its own posts and from reacting
to every integration in a channel. It also means two personas in one
workspace are deaf to each other: Harris was launched as Audel's peer
mentor, and on day one neither could hear a word the other said.

Opening the gate is one line. The reason it was never opened is the loop:
each persona has a responder that answers every message addressed to it.
Persona A posts and mentions B. B answers in the thread. A's bridge sees B's
reply in a thread A is active in, forwards it, A answers. Nothing in that
cycle ever stops, and each turn is an LLM call on a paid key.

## The design

Three settings in the bridge's environment, all optional:

- `SLACK_PEER_BOT_USERS`: comma separated Slack user ids of the other
  personas' bot users (the `U...` id, not the `B...` bot id). Empty, the
  default, keeps the old rule and nothing below applies.
- `SLACK_PEER_MAX_TURNS` (default 4): the most peer messages this bridge
  forwards in one thread in a row with no person speaking in that thread.
- `SLACK_PEER_HOURLY_CAP` (default 30): the most peer messages this bridge
  forwards per hour across every thread.

A post from a listed peer passes the same gate a person's post does: it is
forwarded if it mentions this persona, or if it lands in a thread this
persona is already active in. Then the loop guard decides:

1. Per thread, the bridge counts peer messages it has forwarded since the
   last time a person posted in that thread. Any person's message in the
   thread resets the count to zero, whether or not that message was
   addressed to the persona. At `SLACK_PEER_MAX_TURNS` the bridge stops
   forwarding peer messages in that thread and logs one line saying so.
   Silence is the intended outcome: the conversation waits for a person.
2. Across all threads, a sliding one hour window caps the total. This is
   the backstop for a bridge restart loop or a burst across many threads,
   since the per thread counts live in memory and reset on restart.

With the defaults and two personas, one thread carries at most four
messages from each side, so eight bot posts, before a person has to say
something. That is enough for an exchange and too few for a runaway.

The cap pauses; it does not delete. A peer message refused at either
bound is held for its thread (at most eight, the oldest kept) and
delivered, oldest first, when a person next speaks there — each
delivered hold spending one of the fresh turns, so the bound is never
larger than it was. Before this, a refused message was logged and gone:
the four-message cap dropped real posts that a person speaking a minute
later would have let through.

Both edges of the hold are logged, so the delay is observable without a
sweep: overflow past eight drops the newest message with a warning that
names it, and a person's speech logs how many of the held messages the
fresh turns carried.

## What the mind sees

A forwarded peer message looks like any Slack message in the trajectory,
with the sender named as `slack-<peer user id>-<channel>-<thread ts>`, so
`chat reply` routes back into the same thread with no new code. The header
says what the sender is:

```
(Slack: harris, a Headlong persona like you, not a person in #headlong-bot-chatter — reply with: chat reply slack-U0C2G1517EC-C0C1KSMTBMY-1789377778.721439) ...
```

The responder and the monolith need no change. The persona prompt and the
slack skill tell the mind that a peer is a program with the same bound on
its side, so an unanswered message is the guard, not a snub.

## What is deliberately not done

- No direct transport between boxes. Slack is the only channel, so people
  can read every exchange and step in. A private line between personas
  would defeat the point of a peer mentor working with the team.
- No peer DMs. Slack has no bot to bot direct messages.
- No reactions from peers. A peer's emoji reaction is still dropped like
  any bot event; reactions are not request intent.
- No persistence of the per thread counts or the paused-message holds.
  The hourly cap covers the restart case and keeps the state trivial.

## Rollout

Both boxes run the same bridge. Set `SLACK_PEER_BOT_USERS` in each box's
`.env` to the other persona's bot user id (Audel: `U0BN5FSURBN`, Harris:
`U0C2G1517EC`), mirror it into the laptop env files and the SSM parameters
so a rebuild keeps it, and restart `headlong-slack-bridge` on each box. The
mind does not restart. Turn it off again by unsetting the variable and
restarting the bridge.
