# Wake prompt delivery: the monolith never saw its prompt

Status: 2026-09-03. Part 4 (cached tokens in the ledger) is deployed. Part 1
(run scope render, prompt never cut) is deployed (7a35982, 06:54 UTC) with a
follow-up for the tail window and block eviction (see Prefix caching):
`context --run` and `--full-types`, `shellm --context-scope run`, the
monolith passes it. Part 5 (faithful replay) is done: the old render
engaged the request in 0 of 18 trials and reproduced the live commands,
the run scope render engaged in 12 of 12 at 17K input tokens per call
(`headlong-experiments/pending-request-placement/results.md`).
Relates to: [monolith_thinker.md](monolith_thinker.md),
[monolith_run_health.md](monolith_run_health.md),
[conversation_memory.md](conversation_memory.md),
[context_assembly.md](context_assembly.md), [trajectory_spec.md](trajectory_spec.md).

## The problem we observed

Audel had an open request from Nick since 2026-09-02 13:28 UTC, to finish the
review comments on PRs 84 and 88. The responder had told Nick that Audel would
get back to him and had handed the request to the mind. The monolith read
that request on every timer wake for the next fifteen hours and filed a
research note each time instead. Two rounds of prompt changes, first a nudge
and then a paragraph saying a pending request outranks the menu on any wake,
changed nothing. Each change was verified by reading the prompt step in the
trajectory, which showed the new wording in place.

The replay experiment in
`headlong-experiments/pending-request-placement/` was built to test whether
moving the request higher in the prompt would help. Its control condition,
the recorded prompt sent to the same model, engaged with the request in 15 of
15 trials, while the live mind engaged in 0 of 5 wakes in the same hour. The
replay was not sending what the model was seeing.

## What was happening in the old system

The monolith writes a wake prompt of 45K to 52K characters to a file and
starts `bin/shellm` with `--prompt-file`. Shellm does not send that file to
the model. It appends the prompt as a `prompt` step to the root trajectory,
and on every model call it runs `bin/context` to turn the trajectory into
the message list, with these flags.

```
context --traj_dir DIR ID \
  --assistant-types reasoning,final \
  --user-types prompt,shell-output,feedback \
  --exclude-types shellm-run,run-summary
```

Context keeps the first step and the last 50 steps, and it cuts every field
of every kept step to 2048 bytes, keeping the first 1024, then a stub of the
form `[... truncated: 45367 bytes total. read with: traj show <id> --full]`,
then the last 1024. The limit exists to keep large shell outputs out of the
context window, and the `prompt` step is cut like any other step.

So the model received the shellm system prompt (13.9K characters of generic
bash agent instructions), then about 50 history steps, then 2.1K characters
of the wake prompt. The surviving head is the identity introduction. The
surviving tail is Audel's active goals list, whose last goal says that on
spontaneous wakes with no open request it should pursue research and save it
in a research portfolio before waiting, followed by "Choose ONE function for
this wakeup and carry it out now." The life summary, the recent stream, the
routing signals, the pending request, and the function menu were all in the
removed middle.

The 50 history steps were mostly leftovers from the previous three or four
runs, since a typical run is six or seven steps. They were the model's own
earlier commands as assistant turns and their cut shell outputs as user
turns, plus about 2.5 cut wake prompts from earlier runs. The window slid
forward by two steps on every iteration, and the first message after the
system prompt carried an elided step count that changed every call.

Three behaviours follow from this and all three were observed.

- The research portfolio loop matched the one instruction the model could
  see, its own goals list, reinforced by a history window full of its own
  earlier research notes.
- The one wake that engaged with the request on 09-02 did so because the
  responder's handoff is a short `action` step under 2K, which sat in full
  inside the 50 step window as a user turn. It aged out after about 25 runs.
  The mind was reading the request from its history, not from its prompt.
- Some runs spent turns searching their own prompt files on disk, which is
  what the stub tells the model to do. The 03:49 run on 09-03 searched the
  run directory for "Choose ONE function". The 04:11 run found "pending
  request" at byte 46,347 of its prompt file and then started on PR 84.
  That run was at 302 steps an hour later, and after step 50 it no longer
  saw its own prompt at all. The "context bloat and thrash" in
  monolith_run_health.md issue A is the same behaviour, read at the time as
  the prompt being too big.

Evidence, all from 2026-09-03.

- Synthetic trajectory with one 52K prompt step, current `bin/context`, the
  flags above. The user message is 2,102 characters with no "PENDING
  REQUEST" and no "pick ONE function".
- Same render on the box with the real 04:11 prompt step pinned. 2,185
  characters, same gaps.
- Live first calls used 24K to 29K input tokens. Fifty history steps at
  about 2K each plus the system prompt is that number. A full prompt would
  add about 13K tokens that are not there.
- Every `bin/context` version since 412e08a (2026-05-25) that runs with the
  flags above gives the same 2,102 characters. The 2026-04-28 original wrote
  the prompt record out in full as a task block. Versions between April and
  May had a different interface and were not run. When the wake prompt
  first grew past 2K is not known.
- Ledger for the 24 hours before the finding: 1,135 calls, 27.2M input
  tokens, 1.96M output tokens, mean 24K input per call, about $66 per day at
  grok 4.6 prices ($2 per million input, $6 per million output, $0.50 per
  million cached input).

The write-up with the replay numbers is
`headlong-experiments/pending-request-placement/results.md`.

## What we propose

### 1. Render the current run only, with the wake prompt whole and pinned

The message list for a monolith call becomes the system prompt, then the
full wake prompt as the first user message, then only the steps of the
current run in order. Steps from earlier runs are dropped. In a run longer
than the tail window the prompt stays in as a pinned step and the window
applies to the run's own steps.

Mechanically this is a run filter in `bin/context` (`--run RUN_ID`, pins
always stay, other runs' rows are dropped without an elision marker) plus a
per type exemption from the field limit (`--full-types prompt`). Every step
shellm writes already carries `run_id`, shellm keeps the prompt step id
when it appends it, and context already had `--pin`. Shellm always passes
`--full-types prompt`, so a prompt is never cut in either scope; in the
default trajectory scope that means a resumed conversation's earlier
prompts render whole too, which is what a conversation is. Run scope is
opt in (`--context-scope run`, or `SHELLM_CONTEXT_SCOPE=run`) because a
`--resume` run wants the earlier conversation; the monolith passes it. The
limit on shell output stays as it is.

Why dropping the earlier runs is right. The wake prompt already carries the
last 30 durable steps as its recent stream (in a sampled prompt, 12 finals,
11 idles, 5 messages, 2 observations, no reasoning or shell output), the
tiered life summary, and the pending request list from `chat pending`. The
leftovers repeat that in a worse form, they are about 20K of the 24K input
tokens per call, and they are the material the model imitates when it
loops.

Cost. The first call of a run drops from about 24K input tokens to about
17K, since the full prompt is smaller than the leftovers it replaces. Later
iterations add a few thousand tokens per command and output pair, so a six
call run averages about what it does today. The earlier estimate that
delivering the prompt would add $1.30 per hour assumed the leftovers stayed;
under this design the token cost is roughly neutral. The larger unknown is
behaviour. A mind that sees its requests and menu may run longer and do
more, like the 302 step PR run, and that is the cost we want.

Measured on the first live run under run scope (2026-09-03 07:32 UTC): 96
to 97 percent of input tokens cached for the run's first 50 steps, then a
constant 27,776 cached tokens (the system prompt plus the pinned prompt) once
the 50 row tail window began to slide, about 57 percent. The slide is the
window, not the pin: after 25 iterations a run has more than 50 rows, so the
window drops the run's oldest step on every call and the prefix after the
prompt changes every call. Cached input costs a quarter of the full rate, so
not sliding is cheaper for any run under roughly 115 iterations, and only a
third of a cent per iteration dearer past that. Two knobs fix it. Run scope
now reads a 400 row window (`SHELLM_CONTEXT_RUN_TAIL`, about 200
iterations), so a normal run never slides. And `context --tail-block B`
moves the window's start only every B rows (`SHELLM_CONTEXT_RUN_TAIL_BLOCK`,
default 50), so when a run does outgrow the window the prefix changes once
per 25 iterations instead of on every call. The cap stays a row count and
never a byte budget, because a byte budget rewrites earlier messages and
busts the cache on every call.

Prefix caching. Providers bill the leading part of a request that matches an
earlier request byte for byte at the cached rate. The old render defeated
that beyond the system prompt, because the window slid and the elided count
changed on every call. Under this design nothing before the newest step
changes within a run, so iteration two matches iteration one's whole
request as its prefix, and on a six call run about five calls read the 13K
token prompt at a quarter of the price. Across runs only the system prompt
matches, because the recent stream and the pending ages change each wake.
Ordering the prompt from most stable to most volatile would extend the
match, and the prompt is already roughly in that order. Moving the static
menu earlier would trade a longer match against "Choose ONE function" being
the last thing read, so leave the menu where it is.

What could go wrong, and how to check.

- Format drift. The leftovers were in effect worked examples of writing a
  step with `traj append`. The prompt has a "How to write steps" section
  with the same examples. The replay can count well formed first commands
  under each condition.
- Continuity after a killed run. The next wake sees only durable steps, not
  the last commands. Part 2 addresses that. If it is not enough the fix
  belongs in the final step or the recent stream, not in raw history.
- The responder handoff. It only worked through the leftovers. The pending
  list in the prompt now covers it, so the dependency goes away.

### 2. A richer final step, with a command to dig further

Built 2026-09-03: the prompt's "How to write steps" section asks for a
final that says what was done, what is left, where the work is, and the next
step, and `_recent_stream` stamps every final that has a run id with a
`details` field holding `traj tail --full-scan -n 400 --filter run_id=<id>`. Once the
mind could read its prompt its finals had already started stating
outcomes on their own; the instruction pins that down.

Under part 1 the final step is the only thing the next wake sees about a
run. Shellm stores the model's last reply, the one with no code block, as
the `final` step, so its content is up to the model and steerable from the
prompt. Today's finals are written for nobody, e.g. "Filed remainder
nonfinite gerund-participle direct-object specificity mix cut: Hancock none
vs CoALA nonspecific. Wait."

The prompt should ask for a final that says what was done, what is left,
where the work is, and the next concrete step. For the PR run that would
read something like this.

> Fixed review notes 2, 4, 5 and 6 on PR 84 on branch
> audel/telegram-send-file, round-trip test passes, nothing pushed yet.
> Left: push and reply to Nick on Telegram, then PR 88, not started.
> Next: git push, then chat reply --follow-up.

The next wake's recent stream carries that line, and the mind can continue
without raw history. The line is also readable for people, which the
current finals are not.

Each final should also point at the run it summarises, so the mind can dig
into the raw steps when the summary is not enough. The recent stream
already prints `run_id` on every line, and `traj tail --filter run_id=<id>`
already prints a run's steps, so the prompt can say that a run's details
are available with

```
traj tail --full-scan -n 400 --filter run_id=<run_id>
```

and `traj show <step_id> --full` for one step. The hint should be added by
the monolith when it renders the recent stream, not written by the model,
so it is always present and always correct. A short `traj run <run_id>`
subcommand that prints a run compactly (thoughts, commands, exit codes, and
the final) would be nicer than the filter, and is optional. This is the
same pattern as the stub on cut shell output, applied on purpose to a thing
that is actually a summary.

### 3. Instructions arrive whole or not at all

The truncation stub is right for a long shell output, where the model can
decide whether it needs the rest and fetch it with one command. It is wrong
for the wake prompt, where it sends the model hunting for its own
instructions on disk and only sometimes finding them. Under part 1 the
pinned prompt is never cut, so the stub never appears on it. The rule to
keep is that a prompt is never a field that gets cut, and a recovery hint is
never a substitute for the text.

### 4. Cached input tokens in the usage ledger (built)

`bin/llm` now records `cache_tok`, the part of `in_tok` the provider served
from its prompt cache, on every usage record and ledger line. It reads
`prompt_tokens_details.cached_tokens` from OpenAI and OpenRouter,
`cache_read_input_tokens` from Anthropic, and `cachedContentTokenCount` from
Gemini, in both the streamed and the non-streamed paths. The field is
omitted when the provider reports nothing. `bin/context` hides it from the
model like the other bookkeeping, and `tests/test_llm_retry.sh` and
`tests/test_context.sh` cover it. The hit rate for a call is `cache_tok /
in_tok`. The dash usage page and `deploy/scripts/audel-usage` do not show it
yet.

This is needed before any caching claim above can be trusted. Whether xAI
applies caching automatically through OpenRouter is believed but not
confirmed, and the ledger will show it within a day of deploy.

### 5. Validate with a faithful replay before deploying

Rerun the placement replay on the same six snapshots with three conditions.

- The faithful current render, meaning the cut prompt plus the 50 step
  history window as of that moment. This should reproduce the research note
  and confirm the diagnosis.
- The full prompt plus the same history window.
- The full prompt plus the current run's steps only, which is part 1.

Score the first decision (engaged, declined with a reason, research, idle)
and whether the first command is well formed. To build the faithful render,
copy the trajectory up to the snapshot's prompt step on the box, run
`bin/context` with the production flags against the copy, and pull the
message list.

Done 2026-09-03, 48 calls, about $3.70. The old render engaged in 0 of 18
and produced the same first commands as the live runs, including the
Python script that searches the prompt files on disk. Prompt whole plus
history engaged in 18 of 18 at 61K input tokens per call. Prompt whole in
run scope engaged in 12 of 12 at 17K. Results in
`headlong-experiments/pending-request-placement/results.md`.

## Rollout

1. Part 1 in `bin/context` and `bin/shellm`, with a test that a large
   prompt step renders whole under the production flags and that earlier
   runs' steps are excluded.
2. Part 5 replay, then deploy parts 1 and 4 together.
3. Part 2 prompt change in `thinkers/monolith/prompt.md` and the recent
   stream hint in `thinkers/monolith/step`, after a day of watching the
   finals the mind writes under part 1.
4. Read the ledger after a day for the cache hit rate and the per call
   input tokens, and add the column to the dash if the number is useful.

## Open questions

- When did the wake prompt first exceed 2K characters, and therefore how
  long has the model been running on its goals list alone.
- Whether the earlier proactivity replays in the experiments repo, which
  fed the recorded prompt step in full, need re-reading.
- Whether any other thinker runs shellm with a prompt larger than 2K. The
  responder calls `bin/llm` directly and is not affected.
